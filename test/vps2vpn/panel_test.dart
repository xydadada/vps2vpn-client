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

    test('ignores links that are not vps2vpn subscriptions', () {
      expect(vpsApiBase(''), isNull);
      expect(vpsApiBase('https://example.com/sub?token=$_tok'), isNull);
      expect(vpsApiBase('https://example.com/s/short'), isNull);
      expect(vpsApiBase('https://example.com/s/$_tok/extra'), isNull);
      expect(vpsApiBase('clash://install-config?url=x'), isNull);
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

  test('malformed AI status timestamps never crash or render far-future dates', () {
    for (final at in [double.nan, double.infinity, -1, 9000000000000, 'bad']) {
      final status = VpsAiStatus.fromJson({
        'summary': 'Offline result',
        'at': at,
      });
      expect(status?.at, isNull, reason: 'bad timestamp: $at');
    }
    expect(
      VpsAiStatus.fromJson({'at': 1893456000})?.at?.millisecondsSinceEpoch,
      1893456000000,
    );
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
    expect(h.record('hy2@a', false), isNull, reason: 'already reported');
    expect(h.record('tuic@a', false), isNull, reason: 'lines are separate');
    expect(h.record('hy2@a', true), isTrue);
    expect(h.record('hy2@a', true), isNull);
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

    Uri base() => vpsApiBase(
      'http://127.0.0.1:${server.port}/s/$_tok',
    )!.replace(scheme: 'http'); // plain local test server

    test('fetches the member', () async {
      final r = await fetchMember(base());
      expect(r!.member!.name, 'Ann');
      expect(r.linkChanged, isFalse);
    });

    test('a 404 over plain HTTP does not mean the link was replaced', () async {
      meStatus = HttpStatus.notFound;
      final r = await fetchMember(base());
      expect(r!.linkChanged, isFalse);
      expect(r.problem, VpsPanelProblem.unavailable);
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

  test('token rotation is only trusted over HTTPS', () {
    final base = Uri.parse('https://panel.invalid/s/$_tok/api/');
    final body = jsonEncode({'service': 'vps2vpn', 'error': 'token_invalid'});
    expect(VpsMemberResult.fromResponse(base, 401, body).linkChanged, isTrue);
    expect(
      VpsMemberResult.fromResponse(
        base.replace(scheme: 'http'),
        401,
        body,
      ).linkChanged,
      isFalse,
    );
    // The panel answers an unknown token with a bare 404.
    expect(VpsMemberResult.fromResponse(base, 404, '').linkChanged, isTrue);
    expect(
      VpsMemberResult.fromResponse(
        base.replace(scheme: 'http'),
        404,
        '',
      ).linkChanged,
      isFalse,
    );
    final up = jsonEncode({'service': 'vps2vpn', 'error': 'https_required'});
    expect(
      VpsMemberResult.fromResponse(
        base.replace(scheme: 'http'),
        426,
        up,
      ).problem,
      VpsPanelProblem.httpsRequired,
    );
  });

  test(
    'a release is only downloaded over HTTPS with a plain file name',
    () async {
      final dir = await Directory.systemTemp.createTemp('v2v-release');
      addTearDown(() => dir.delete(recursive: true));
      await expectLater(
        vpsDownloadRelease(
          Uri.parse(
            'http://panel.invalid/s/$_tok/download/vps2vpn-1.0.3-windows-amd64-setup.exe',
          ),
          dir,
        ),
        throwsA(isA<HttpException>()),
      );
      await expectLater(
        vpsDownloadRelease(
          Uri.parse('https://panel.invalid/s/$_tok/download/..%5Cevil.exe'),
          dir,
        ),
        throwsA(isA<HttpException>()),
      );
      expect(dir.listSync(), isEmpty);
    },
  );
}
