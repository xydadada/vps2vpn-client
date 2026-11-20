import 'dart:convert';
import 'dart:io';

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
        'https://1.2.3.4:43470/s/$_tok/api/',
      );
    });

    test('keeps the panel port when upgrading default HTTP ports', () {
      for (final host in ['panel.example', 'panel.example:80']) {
        expect(
          vpsApiBase('http://$host/s/$_tok').toString(),
          'https://panel.example:80/s/$_tok/api/',
        );
      }
    });

    test('ignores links that are not vps2vpn subscriptions', () {
      expect(vpsApiBase(''), isNull);
      expect(vpsApiBase('https:///s/$_tok'), isNull);
      expect(vpsApiBase('https://example.com/sub?token=$_tok'), isNull);
      expect(vpsApiBase('https://example.com/s/short'), isNull);
      expect(vpsApiBase('https://example.com/s/$_tok/extra'), isNull);
      expect(vpsApiBase('clash://install-config?url=x'), isNull);
    });
  });

  test('accepts certificate pins only for the exact panel host', () {
    final pin = 'ab' * 32;
    final base = vpsApiBase('http://panel.example:43470/s/$_tok')!;
    expect(
      vpsCertificatePins(base, {
        'tls-fingerprints': {
          'other.example': [pin],
          'panel.example': [pin, 'invalid', 123],
        },
      }),
      {pin},
    );
    expect(
      vpsCertificatePins(base, {
        'tls-fingerprints': {
          'other.example': [pin],
        },
      }),
      isEmpty,
    );
    expect(vpsCertificatePins(base, {}), isEmpty);
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

  test('invalid panel timestamps do not break the member result', () {
    for (final value in [
      -1,
      253402300800,
      9223372036854775807,
      1e100,
      double.infinity,
      double.nan,
      'not a date',
    ]) {
      final member = VpsMember.fromJson({
        'name': 'Ann',
        'expire_at': value,
        'ai': {'summary': 'ok', 'at': value},
      });
      expect(member.name, 'Ann');
      expect(member.expireAt, isNull);
      expect(member.ai?.at, isNull);
    }
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

  test('retries a change until the panel acknowledges it', () {
    final h = VpsLineHealth(threshold: 2);
    expect(h.record('hy2@a', false), isNull);
    expect(h.record('hy2@a', false), isFalse);
    expect(h.record('hy2@a', false), isFalse);
    h.acknowledge('hy2@a', false);
    expect(h.record('hy2@a', false), isNull);
    expect(h.record('hy2@a', true), isTrue);
    expect(h.record('hy2@a', true), isTrue);
    h.acknowledge('hy2@a', true);
    expect(h.record('hy2@a', true), isNull);
  });

  test('does not report recovery for an unacknowledged outage', () {
    final h = VpsLineHealth(threshold: 1);
    expect(h.record('hy2@a', false), isFalse);
    expect(h.record('hy2@a', true), isNull);
  });

  group('against a local panel', () {
    late HttpServer server;
    final posts = <(String?, Object?)>[];
    var meStatus = HttpStatus.ok;
    String? meBody;
    String? redirect;

    setUp(() async {
      posts.clear();
      meStatus = HttpStatus.ok;
      meBody = null;
      redirect = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final path = req.uri.path;
        if (path == '/s/$_tok/api/me' && req.method == 'GET') {
          req.response.statusCode = meStatus;
          if (redirect != null) {
            req.response.headers.set(HttpHeaders.locationHeader, redirect!);
          }
          req.response.write(
            meBody ?? jsonEncode({'name': 'Ann', 'enabled': true}),
          );
        } else if (path == '/s/$_tok/api/report' &&
            req.method == 'POST' &&
            req.contentLength < 0) {
          // Require fixed framing here; current panels also accept chunked bodies.
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

    // Exercise HTTP framing here; panel_tls_test covers the production TLS path.
    Uri base() => Uri.parse('http://127.0.0.1:${server.port}/s/$_tok/api/');

    test('fetches the member', () async {
      final r = await fetchMember(base());
      expect(r!.member!.name, 'Ann');
      expect(r.linkChanged, isFalse);
    });

    test('does not follow a redirect into an unrelated 404', () async {
      meStatus = HttpStatus.found;
      redirect = '/login';
      expect(await fetchMember(base()), isNull);
    });

    test('rejects an oversized panel body', () async {
      meBody = jsonEncode({'name': 'a' * (1024 * 1024)});
      expect(await fetchMember(base()), isNull);
    });

    test('authenticates only to the configured fallback proxy', () async {
      meStatus = HttpStatus.serviceUnavailable;
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      final authorization = 'Basic ${base64Encode(utf8.encode('user:p:a@ss'))}';
      var accepted = 0;
      proxy.listen((request) async {
        if (request.headers.value(HttpHeaders.proxyAuthorizationHeader) !=
            authorization) {
          request.response
            ..statusCode = HttpStatus.proxyAuthenticationRequired
            ..headers.set(HttpHeaders.proxyAuthenticateHeader, 'Basic realm="local"');
        } else {
          accepted++;
          request.response.write(jsonEncode({'name': 'Via proxy'}));
        }
        await request.response.close();
      });
      final result = await fetchMember(
        base(),
        proxyPort: proxy.port,
        proxyCredentials: 'user:p:a@ss',
      );
      expect(result?.member?.name, 'Via proxy');
      expect(accepted, 1);
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
