import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/vps2vpn/auto_update.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:fl_clash/vps2vpn/update_signing.dart';
import 'package:flutter_test/flutter_test.dart';

class _SocketOverrides extends HttpOverrides {}

// A throwaway Ed25519 key (not the release key) and its openssl signatures of
// "release payload" under each file name the server below serves.
const _testKey =
    'f5be85b6ef9f1a0df2c79f83de5af4b290597411d85f7271acddf4a547a9dc78';
const _signatures = {
  'client.exe':
      'G5QI07sAi5a2w/J4GFlvHm/SNWMXKuNmOeRNG5yzKS5hw1O6BLokkf4joib/agWrvRzrhpEAhfClZkKqijx9Bw==',
  'CLIENT.EXE':
      'GJvQw/RubmgtTeqGzkylasT3O99Ves/+o8Nf6dxL+dC6W+7hXPjjLYN/gQqrb9C2prE2cUFW8LK/Gak7I78zAQ==',
  'vps2vpn-1.0.9-windows-amd64-setup.exe':
      'bbD6sNdlQp50rGP2o5n3AbqubRpAyEu8G+9iw7nw6Z6+BjX6PgVJB5lM3VKfKilITHzrjUYxUZlHtpVUoSfEDQ==',
  // signed for another file: valid base64, wrong signature here
  'vps2vpn-1.0.9-windows-amd64-portable.zip':
      'G5QI07sAi5a2w/J4GFlvHm/SNWMXKuNmOeRNG5yzKS5hw1O6BLokkf4joib/agWrvRzrhpEAhfClZkKqijx9Bw==',
};

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
    server.listen((request) async {
      final name = request.uri.pathSegments.last;
      if (name.endsWith('.sig')) {
        final sig = _signatures[name.substring(0, name.length - 4)];
        if (sig == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.writeln(sig);
        }
      } else {
        request.response.write('release payload');
      }
      await request.response.close();
    }, onError: (Object _) {});
  });

  tearDown(() => server.close(force: true));

  test(
    'a predictable part symlink cannot overwrite an unrelated file',
    () async {
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
          publicKeyHex: _testKey,
        ),
      );

      expect(await downloaded.readAsString(), 'release payload');
      expect(await victim.readAsString(), 'untouched');
      expect(await link.exists(), isTrue);
      expect(dir.listSync().whereType<Directory>(), isEmpty);
    },
  );

  test('two concurrent downloads cannot share one destination', () async {
    final dir = await Directory.systemTemp.createTemp('v2v-release-race-');
    addTearDown(() => dir.delete(recursive: true));
    final url = Uri.parse('https://127.0.0.1:${server.port}/client.exe');

    final first = _localSocket(
      () => vpsDownloadRelease(
        url,
        dir,
        pinnedSha256: {fingerprint},
        publicKeyHex: _testKey,
      ),
    );
    await expectLater(
      _localSocket(
        () => vpsDownloadRelease(
          url,
          dir,
          pinnedSha256: {fingerprint},
          publicKeyHex: _testKey,
        ),
      ),
      throwsA(isA<HttpException>()),
    );

    final downloaded = await first;
    expect(await downloaded.readAsString(), 'release payload');
    expect(dir.listSync().whereType<Directory>(), isEmpty);
  });

  test(
    'path aliases of a symlinked download directory share one lock',
    () async {
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
            () => vpsDownloadRelease(
              url,
              dir,
              pinnedSha256: {fingerprint},
              publicKeyHex: _testKey,
            ),
          );
        } catch (e) {
          return e;
        }
      }

      final results = await Future.wait([
        download(real),
        download(Directory(alias.path)),
      ]);
      expect(results.whereType<File>().length, 1);
      expect(results.whereType<HttpException>().length, 1);
      expect(
        await File(
          '${real.path}${Platform.pathSeparator}client.exe',
        ).readAsString(),
        'release payload',
      );
    },
  );

  test(
    'Windows case-folded filenames cannot bypass the active download lock',
    () async {
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
              publicKeyHex: _testKey,
            ),
          );
        } catch (e) {
          return e;
        }
      }

      final results = await Future.wait([
        download('client.exe'),
        download('CLIENT.EXE'),
      ]);
      expect(results.whereType<File>().length, 1);
      expect(results.whereType<HttpException>().length, 1);
      expect(
        await File(
          '${dir.path}${Platform.pathSeparator}client.exe',
        ).readAsString(),
        'release payload',
      );
    },
  );

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

  test('a fetched installer is offered again on the next start', () async {
    final dir = await Directory.systemTemp.createTemp('v2v-release-keep-');
    addTearDown(() => dir.delete(recursive: true));
    const name = 'vps2vpn-1.0.9-windows-amd64-setup.exe';
    final saved = await _localSocket(
      () => vpsDownloadRelease(
        Uri.parse('https://127.0.0.1:${server.port}/$name'),
        dir,
        pinnedSha256: {fingerprint},
        currentVersion: '1.0.8',
        publicKeyHex: _testKey,
      ),
    );
    expect(File('${saved.path}.sig').existsSync(), isTrue);

    final ready = await vpsReadyInstaller(dir, '1.0.8', publicKeyHex: _testKey);
    expect(ready?.$1, '1.0.9');
    expect(ready?.$2.path, saved.path);
    expect(
      await vpsReadyInstaller(dir, '1.0.9', publicKeyHex: _testKey),
      isNull,
      reason: 'installed already',
    );
    await saved.writeAsString('tampered payload');
    expect(
      await vpsReadyInstaller(dir, '1.0.8', publicKeyHex: _testKey),
      isNull,
    );
    await saved.writeAsString('release payload');
    await File('${saved.path}.sig').delete();
    expect(
      await vpsReadyInstaller(dir, '1.0.8', publicKeyHex: _testKey),
      isNull,
    );
  });

  group('the installer is checked again before it runs', () {
    const name = 'vps2vpn-1.0.9-windows-amd64-setup.exe';
    late Directory dir;
    late File installer;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('v2v-release-recheck-');
      installer = File('${dir.path}${Platform.pathSeparator}$name');
      await installer.writeAsString('release payload');
      await File('${installer.path}.sig').writeAsString(_signatures[name]!);
    });
    tearDown(() => dir.delete(recursive: true));

    Future<bool> verified([String? path]) =>
        vpsInstallerVerified(path ?? installer.path, publicKeyHex: _testKey);

    test('the signed bytes pass', () async {
      expect(await verified(), isTrue);
    });

    test('bytes changed after the download fail', () async {
      await installer.writeAsString('release payloaD');
      expect(await verified(), isFalse);
    });

    test('a missing, empty or unreadable signature fails', () async {
      final sig = File('${installer.path}.sig');
      await sig.writeAsBytes([0xff, 0xfe, 0x00]);
      expect(await verified(), isFalse);
      await sig.writeAsString('');
      expect(await verified(), isFalse);
      await sig.delete();
      expect(await verified(), isFalse);
    });

    test('a folder in place of the installer or signature fails', () async {
      await File('${installer.path}.sig').delete();
      await Directory('${installer.path}.sig').create();
      expect(await verified(), isFalse);
      expect(await verified(dir.path), isFalse);
    });

    test('a link to the signed installer fails', () async {
      final other = await Directory('${dir.path}/other').create();
      final link = '${other.path}${Platform.pathSeparator}$name';
      try {
        await Link(link).create(installer.path);
        await Link('$link.sig').create('${installer.path}.sig');
      } on FileSystemException {
        markTestSkipped('this system does not allow links');
        return;
      }
      expect(await verified(link), isFalse);
    });
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
        publicKeyHex: _testKey,
      ),
    );
    expect(saved.path, out.path);
    expect(await out.readAsString(), 'release payload');
    expect(dir.listSync().whereType<Directory>(), isEmpty);
  });

  test(
    'failed TLS validation preserves an existing installer and cleans staging',
    () async {
      final dir = await Directory.systemTemp.createTemp('v2v-release-fail-');
      addTearDown(() => dir.delete(recursive: true));
      final out = File('${dir.path}${Platform.pathSeparator}client.exe');
      await out.writeAsString('previous version');
      final url = Uri.parse('https://127.0.0.1:${server.port}/client.exe');

      await expectLater(
        _localSocket(
          () => vpsDownloadRelease(
            url,
            dir,
            pinnedSha256: {'00' * 32},
            publicKeyHex: _testKey,
          ),
        ),
        throwsA(anything),
      );

      expect(await out.readAsString(), 'previous version');
      expect(dir.listSync().whereType<Directory>(), isEmpty);
    },
  );

  group('update signature', () {
    Uri link(String name) =>
        Uri.parse('https://127.0.0.1:${server.port}/s/token/download/$name');

    test('a signed, newer installer is kept', () async {
      final dir = await Directory.systemTemp.createTemp('v2v-release-sig-');
      addTearDown(() => dir.delete(recursive: true));
      final saved = await _localSocket(
        () => vpsDownloadRelease(
          link('vps2vpn-1.0.9-windows-amd64-setup.exe'),
          dir,
          pinnedSha256: {fingerprint},
          currentVersion: '1.0.8',
          publicKeyHex: _testKey,
        ),
      );
      expect(await saved.readAsString(), 'release payload');
    });

    Future<void> refused(
      String name,
      String reason, {
      String current = '1.0.8',
      String key = _testKey,
    }) async {
      final dir = await Directory.systemTemp.createTemp('v2v-release-bad-');
      addTearDown(() => dir.delete(recursive: true));
      final previous = File('${dir.path}${Platform.pathSeparator}$name');
      await previous.writeAsString('previous version');
      await expectLater(
        _localSocket(
          () => vpsDownloadRelease(
            link(name),
            dir,
            pinnedSha256: {fingerprint},
            currentVersion: current,
            publicKeyHex: key,
          ),
        ),
        throwsA(
          isA<VpsUpdateRejected>().having((e) => e.reason, 'reason', reason),
        ),
      );
      // nothing of the refused download is left, the old file is untouched
      expect(await previous.readAsString(), 'previous version');
      expect(dir.listSync().whereType<Directory>(), isEmpty);
    }

    test('a wrong signature is refused', () async {
      await refused('vps2vpn-1.0.9-windows-amd64-portable.zip', 'badSignature');
    });

    test('a signature by another key is refused', () async {
      await refused(
        'vps2vpn-1.0.9-windows-amd64-setup.exe',
        'badSignature',
        key: vpsUpdatePublicKeyHex,
      );
    });

    test('an unsigned installer is refused', () async {
      await refused('vps2vpn-1.0.9-android-arm64.apk', 'unsigned');
    });

    test('an installer that is not newer is refused before download', () async {
      await refused(
        'vps2vpn-1.0.9-windows-amd64-setup.exe',
        'notNewer',
        current: '1.0.9',
      );
      await refused('client.exe', 'notNewer');
    });
  });
}
