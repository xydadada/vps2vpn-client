import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter_test/flutter_test.dart';

class _SocketOverrides extends HttpOverrides {}

Future<T> _localSocket<T>(Future<T> Function() call) =>
    HttpOverrides.runWithHttpOverrides(call, _SocketOverrides());

void main() {
  late HttpServer server;
  late String fingerprint;

  setUp(() async {
    final certificate = await File(
      'test/fixtures/panel/localhost.cert.pem',
    ).readAsString();
    final key = await File(
      'test/fixtures/panel/localhost.key.pem',
    ).readAsBytes();
    final der = base64Decode(
      certificate
          .replaceAll('-----BEGIN CERTIFICATE-----', '')
          .replaceAll('-----END CERTIFICATE-----', '')
          .replaceAll(RegExp(r'\s'), ''),
    );
    fingerprint = sha256.convert(der).toString();
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(certificate))
      ..usePrivateKeyBytes(key);
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server.listen(
      (request) async {
        request.response.write('release payload');
        await request.response.close();
      },
      onError: (Object _) {},
    );
  });

  tearDown(() => server.close(force: true));

  test('a predictable part symlink cannot overwrite an unrelated file', () async {
    if (Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('v2v-release-link-');
    addTearDown(() => dir.delete(recursive: true));
    final victim = File('${dir.path}${Platform.pathSeparator}victim.txt');
    await victim.writeAsString('untouched');
    final link = Link('${dir.path}${Platform.pathSeparator}client.exe.part');
    await link.create(victim.path);

    final downloaded = await _localSocket(
      () => vpsDownloadRelease(
        Uri.parse('https://127.0.0.1:${server.port}/client.exe'),
        dir,
        pinnedSha256: {fingerprint},
      ),
    );

    expect(await downloaded.readAsString(), 'release payload');
    expect(await victim.readAsString(), 'untouched');
    expect(await link.exists(), isTrue);
    expect(dir.listSync().whereType<Directory>(), isEmpty);
  });

  test('two concurrent downloads cannot share one destination', () async {
    final dir = await Directory.systemTemp.createTemp('v2v-release-race-');
    addTearDown(() => dir.delete(recursive: true));
    final url = Uri.parse('https://127.0.0.1:${server.port}/client.exe');

    final first = _localSocket(
      () => vpsDownloadRelease(url, dir, pinnedSha256: {fingerprint}),
    );
    await expectLater(
      _localSocket(
        () => vpsDownloadRelease(url, dir, pinnedSha256: {fingerprint}),
      ),
      throwsA(isA<HttpException>()),
    );

    final downloaded = await first;
    expect(await downloaded.readAsString(), 'release payload');
    expect(dir.listSync().whereType<Directory>(), isEmpty);
  });

  test('path aliases of a symlinked download directory share one lock', () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('v2v-release-alias-');
    addTearDown(() => root.delete(recursive: true));
    final real = Directory('${root.path}${Platform.pathSeparator}real');
    await real.create();
    final alias = Link('${root.path}${Platform.pathSeparator}alias');
    await alias.create(real.path);
    final url = Uri.parse('https://127.0.0.1:${server.port}/client.exe');

    Future<Object> download(Directory dir) async {
      try {
        return await _localSocket(
          () => vpsDownloadRelease(url, dir, pinnedSha256: {fingerprint}),
        );
      } catch (e) {
        return e;
      }
    }

    final results = await Future.wait([download(real), download(Directory(alias.path))]);
    expect(results.whereType<File>().length, 1);
    expect(results.whereType<HttpException>().length, 1);
    expect(await File('${real.path}${Platform.pathSeparator}client.exe').readAsString(),
        'release payload');
  });

  test('Windows case-folded filenames cannot bypass the active download lock', () async {
    if (!Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('v2v-release-case-');
    addTearDown(() => dir.delete(recursive: true));

    Future<Object> download(String name) async {
      try {
        return await _localSocket(
          () => vpsDownloadRelease(
            Uri.parse('https://127.0.0.1:${server.port}/$name'),
            dir,
            pinnedSha256: {fingerprint},
          ),
        );
      } catch (e) {
        return e;
      }
    }

    final results = await Future.wait([download('client.exe'), download('CLIENT.EXE')]);
    expect(results.whereType<File>().length, 1);
    expect(results.whereType<HttpException>().length, 1);
    expect(await File('${dir.path}${Platform.pathSeparator}client.exe').readAsString(),
        'release payload');
  });

  test('rejects DOS device names and trailing-dot file aliases', () async {
    final dir = await Directory.systemTemp.createTemp('v2v-release-names-');
    addTearDown(() => dir.delete(recursive: true));
    for (final name in [
      'CON',
      'NUL.txt',
      'LPT1.exe',
      'COM9',
      'client.',
      'client..',
    ]) {
      final url = Uri.parse('https://127.0.0.1:${server.port}/$name');
      await expectLater(
        vpsDownloadRelease(url, dir),
        throwsA(isA<HttpException>()),
        reason: name,
      );
    }
    expect(dir.listSync(), isEmpty);
  });

  test('verified download replaces an existing complete installer', () async {
    final dir = await Directory.systemTemp.createTemp('v2v-release-replace-');
    addTearDown(() => dir.delete(recursive: true));
    final out = File('${dir.path}${Platform.pathSeparator}client.exe');
    await out.writeAsString('previous release');

    final saved = await _localSocket(
      () => vpsDownloadRelease(
        Uri.parse('https://127.0.0.1:${server.port}/client.exe'),
        dir,
        pinnedSha256: {fingerprint},
      ),
    );
    expect(saved.path, out.path);
    expect(await out.readAsString(), 'release payload');
    expect(dir.listSync().whereType<Directory>(), isEmpty);
  });

  test('failed TLS validation preserves an existing installer and cleans staging', () async {
    final dir = await Directory.systemTemp.createTemp('v2v-release-fail-');
    addTearDown(() => dir.delete(recursive: true));
    final out = File('${dir.path}${Platform.pathSeparator}client.exe');
    await out.writeAsString('previous version');
    final url = Uri.parse('https://127.0.0.1:${server.port}/client.exe');

    await expectLater(
      _localSocket(
        () => vpsDownloadRelease(url, dir, pinnedSha256: {'00' * 32}),
      ),
      throwsA(anything),
    );

    expect(await out.readAsString(), 'previous version');
    expect(dir.listSync().whereType<Directory>(), isEmpty);
  });
}
