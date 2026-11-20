import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter_test/flutter_test.dart';

const _tok = 'AbCdEf0123456789xyzQ';

void main() {
  group('api base', () {
    test('drops the query and adds /api/', () {
      expect(
        vpsApiBase('https://1.2.3.4:43470/s/$_tok?format=clash').toString(),
        'https://1.2.3.4:43470/s/$_tok/api/',
      );
      expect(
        vpsApiBase('http://1.2.3.4:43470/s/$_tok').toString(),
        'http://1.2.3.4:43470/s/$_tok/api/',
      );
    });

    test('ignores links that are not vps2vpn subscriptions', () {
      expect(vpsApiBase(''), isNull);
      expect(vpsApiBase('https://example.com/sub?token=$_tok'), isNull);
      expect(vpsApiBase('https://example.com/s/short'), isNull);
      expect(vpsApiBase('https://example.com/s/$_tok/extra'), isNull);
      expect(vpsApiBase('clash://install-config?url=x'), isNull);
      expect(vpsApiBase('https:/s/$_tok'), isNull);
      expect(vpsApiBase('https://user:password@host/s/$_tok'), isNull);
      expect(vpsApiBase('https://host//s/$_tok'), isNull);
      expect(vpsApiBase('https://host/s//$_tok'), isNull);
    });
  });

  test('reads the member fields the panel sends', () {
    final m = VpsMember.fromJson({
      'name': 'Ann',
      'enabled': false,
      'disabled_reason': 'quota',
      'used_up': 100,
      'used_down': 400,
      'quota_gb': 10,
      'quota_eff': 15,
      'expire_at': 1893456000,
      'ai': {
        'summary': 'Claude ok',
        'place': 'Singapore',
        'at': 1893456000,
        'sites': {'claude': 'ok', 'chatgpt': 'blocked'},
      },
    });
    expect(m.enabled, isFalse);
    expect(m.disabledReason, 'quota');
    expect(m.used, 500);
    expect(m.quotaGb, 15);
    expect(m.expireAt!.millisecondsSinceEpoch, 1893456000 * 1000);
    expect(m.ai!.sites, {'claude': 'ok', 'chatgpt': 'blocked'});
    expect(VpsMember.fromJson({'ai': null, 'expire_at': 0}).ai, isNull);
    expect(VpsMember.fromJson({'expire_at': 0}).expireAt, isNull);
  });

  test('a published client is offered only when it is newer', () {
    final r = VpsClientRelease.fromJson({
      'version': 'v1.4.0',
      'url': 'https://1.2.3.4:43470/dl/vps2vpn-setup.exe',
    })!;
    expect(r.version, '1.4.0');
    expect(r.newerThan('1.3.9'), isTrue);
    expect(r.newerThan('1.4.0+12'), isFalse);
    expect(r.newerThan('1.10.0'), isFalse);
    expect(r.newerThan('dev'), isFalse);
    expect(
      VpsClientRelease.fromJson({'version': '2.0', 'url': 'file:///c:/x'}),
      isNull,
    );
    expect(VpsClientRelease.fromJson(null), isNull);
    for (final url in ['https:/setup.exe', 'https://user:password@host/x']) {
      expect(
        VpsClientRelease.fromJson({'version': '2.0', 'url': url}),
        isNull,
      );
    }
  });

  test('prefers the installer the panel holds for this platform', () {
    final r = VpsClientRelease.fromJson({
      'version': '1.10.0',
      'url': 'https://panel/s/t/download/vps2vpn-1.10.0-windows-setup.exe',
      'notes': '',
      'files': {
        'windows':
            'https://panel/s/t/download/vps2vpn-1.10.0-windows-setup.exe',
        'android': 'https://panel/s/t/download/vps2vpn-1.10.0-android.apk',
        'bad': 'javascript:alert(1)',
      },
    })!;
    expect(r.notes, isNull);
    expect(r.newerThan('1.2.0'), isTrue);
    expect(r.downloadFor('android').path, endsWith('android.apk'));
    expect(r.downloadFor('linux'), r.url);
    expect(r.files.containsKey('bad'), isFalse);
    final onlyFiles = VpsClientRelease.fromJson({
      'version': '2.0.0',
      'files': {'windows': 'https://panel/x.exe'},
    })!;
    expect(onlyFiles.url.toString(), 'https://panel/x.exe');
  });

  test('names the line kinds the panel knows', () {
    expect(vpsLineKind({'type': 'hysteria2'}), 'hy2');
    expect(vpsLineKind({'type': 'tuic'}), 'tuic');
    expect(
      vpsLineKind({
        'type': 'vless',
        'reality-opts': {'public-key': 'k'},
      }),
      'reality',
    );
    expect(vpsLineKind({'type': 'vless'}), isNull);
    expect(vpsLineKind({'type': 'ss'}), isNull);
  });

  test('reports a line once when it keeps failing and once when back', () {
    final h = VpsLineHealth(threshold: 3);
    expect(h.record('hy2@a', false), isNull);
    expect(h.record('hy2@a', true), isNull, reason: 'a blip says nothing');
    expect(h.record('hy2@a', false), isNull);
    expect(h.record('hy2@a', false), isNull);
    expect(h.record('hy2@a', false), isFalse);
    h.acknowledge('hy2@a', false);
    expect(h.record('hy2@a', false), isNull, reason: 'already reported');
    expect(h.record('tuic@a', false), isNull, reason: 'lines are separate');
    expect(h.record('hy2@a', true), isTrue);
    h.acknowledge('hy2@a', true);
    expect(h.record('hy2@a', true), isNull);
  });

  test('failed reports retry with the latest observed health', () {
    final health = VpsLineHealth(threshold: 2);
    expect(health.record('a', false), isNull);
    expect(health.record('a', false), isFalse);
    expect(health.record('a', false), isFalse);
    expect(health.record('a', true), isTrue);
    health.acknowledge('a', true);
    expect(health.record('a', false), isNull);
    expect(health.record('a', false), isFalse);
    health.acknowledge('a', false);
    expect(health.record('a', true), isTrue);
    expect(health.record('a', true), isTrue);
    health.acknowledge('a', true);
    expect(health.record('a', true), isNull);
  });

  group('network boundaries', () {
    test('does not follow a panel redirect to another destination', () async {
      final destination = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => destination.close(force: true));
      addTearDown(() => source.close(force: true));
      var visits = 0;
      destination.listen((req) async {
        visits++;
        req.response.write('{"name":"redirected"}');
        await req.response.close();
      });
      source.listen((req) async {
        req.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${destination.port}/s/$_tok/api/me',
          );
        await req.response.close();
      });

      final result = await fetchMember(
        vpsApiBase('http://127.0.0.1:${source.port}/s/$_tok')!,
      );
      expect(result, isNull);
      expect(visits, 0);
    });

    test('rejects an oversized streamed panel response', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.write(jsonEncode({'name': 'x' * ((1 << 20) + 1)}));
        try {
          await req.response.close();
        } on SocketException {
          // A bounded reader may close before the complete response is sent.
        } on HttpException {
          // The client has rejected this response.
        }
      });

      expect(
        await fetchMember(
          vpsApiBase('http://127.0.0.1:${server.port}/s/$_tok')!,
        ),
        isNull,
      );
    });

    test('uses local proxy credentials only after a proxy challenge', () async {
      final direct = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => direct.close(force: true));
      addTearDown(() => proxy.close(force: true));
      String? proxyCredentials;
      direct.listen((req) async {
        expect(req.headers.value(HttpHeaders.authorizationHeader), isNull);
        expect(req.headers.value(HttpHeaders.proxyAuthorizationHeader), isNull);
        req.response.statusCode = HttpStatus.serviceUnavailable;
        await req.response.close();
      });
      proxy.listen((req) async {
        final credentials = req.headers.value(
          HttpHeaders.proxyAuthorizationHeader,
        );
        if (credentials == null) {
          req.response
            ..statusCode = HttpStatus.proxyAuthenticationRequired
            ..headers.set(
              HttpHeaders.proxyAuthenticateHeader,
              'Basic realm="vps2vpn-test"',
            );
        } else {
          proxyCredentials = credentials;
          req.response.write('{"name":"Ann","enabled":true}');
        }
        await req.response.close();
      });

      final result = await fetchMember(
        vpsApiBase('http://127.0.0.1:${direct.port}/s/$_tok')!,
        proxyPort: proxy.port,
        authentication: const AuthenticationProps(
          enable: true,
          username: 'member',
          password: 'local-secret',
        ),
      );
      expect(result?.member?.name, 'Ann');
      expect(
        proxyCredentials,
        'Basic ${base64.encode(utf8.encode('member:local-secret'))}',
      );
    });
  });

  group('against a local panel', () {
    late HttpServer server;
    final posts = <(String?, Object?)>[];
    var meStatus = HttpStatus.ok;

    setUp(() async {
      posts.clear();
      meStatus = HttpStatus.ok;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final path = req.uri.path;
        if (path == '/s/$_tok/api/me' && req.method == 'GET') {
          req.response.statusCode = meStatus;
          req.response.write(jsonEncode({'name': 'Ann', 'enabled': true}));
        } else if (path == '/s/$_tok/api/report' &&
            req.method == 'POST' &&
            req.contentLength < 0) {
          // Like the panel's Python server: a chunked body reads as empty.
          req.response.statusCode = HttpStatus.badRequest;
        } else if (path == '/s/$_tok/api/report' && req.method == 'POST') {
          posts.add((
            req.headers.value('X-V2V'),
            jsonDecode(await utf8.decodeStream(req)),
          ));
          req.response.write('{"ok":true}');
        } else {
          req.response.statusCode = HttpStatus.notFound;
        }
        await req.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    Uri base() => vpsApiBase('http://127.0.0.1:${server.port}/s/$_tok')!;

    test('fetches the member', () async {
      final r = await fetchMember(base());
      expect(r!.member!.name, 'Ann');
      expect(r.linkChanged, isFalse);
    });

    test('a 404 means the link was replaced', () async {
      meStatus = HttpStatus.notFound;
      final r = await fetchMember(base());
      expect(r!.linkChanged, isTrue);
    });

    test('a report carries the header and the line', () async {
      expect(
        await reportLine(base(), line: 'hy2', ok: false, host: '1.2.3.4'),
        isTrue,
      );
      expect(posts.single.$1, '1');
      expect(posts.single.$2, {'line': 'hy2', 'ok': false, 'host': '1.2.3.4'});
    });
  });
}
