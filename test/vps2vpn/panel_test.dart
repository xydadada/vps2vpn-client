import 'dart:async';
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

    test('the member centre is the link page itself, over HTTPS', () {
      expect(
        vpsMemberPage('http://1.2.3.4:43470/s/$_tok?format=clash').toString(),
        'https://1.2.3.4:43470/s/$_tok/',
      );
      expect(vpsMemberPage('https://example.com/sub?token=$_tok'), isNull);
      expect(vpsMemberPage(''), isNull);
    });

    test('a member centre address copied from the browser imports as the '
        'subscription', () {
      expect(
        vpsSubscriptionLink('https://1.2.3.4:43470/s/$_tok/'),
        'https://1.2.3.4:43470/s/$_tok',
      );
      expect(
        vpsSubscriptionLink('https://1.2.3.4:43470/s/$_tok/index.html#usage'),
        'https://1.2.3.4:43470/s/$_tok',
      );
      expect(
        vpsSubscriptionLink('http://1.2.3.4:43470/s/$_tok/?format=clash'),
        'http://1.2.3.4:43470/s/$_tok?format=clash',
      );
      expect(
        vpsSubscriptionLink('https://1.2.3.4:43470/s/$_tok#invites'),
        'https://1.2.3.4:43470/s/$_tok',
      );
      // Everything else is left alone.
      for (final other in [
        'https://1.2.3.4:43470/s/$_tok',
        'https://1.2.3.4:43470/s/$_tok/api/',
        'https://example.com/sub/',
        'clash://install-config?url=x',
      ]) {
        expect(vpsSubscriptionLink(other), other);
      }
    });

    test('the import question names only the host, never the secret path', () {
      expect(
        vpsLinkSource('https://panel.example.com:43470/s/$_tok?format=clash'),
        'panel.example.com',
      );
      expect(vpsLinkSource('vless://uuid@host:443'), isNull);
      expect(vpsLinkSource('not a link'), isNull);
    });

    test('the unasked test import takes only an address on this PC', () {
      for (final local in [
        'http://127.0.0.1:18000/sub.yaml',
        'http://localhost:18000/sub.yaml',
        'http://[::1]:18000/sub.yaml',
      ]) {
        expect(vpsLoopbackLink(local), local);
      }
      for (final other in [
        null,
        'https://panel.example.com/s/$_tok',
        'http://127.0.0.1.example.com/sub.yaml',
        'file:///C:/sub.yaml',
      ]) {
        expect(vpsLoopbackLink(other), isNull);
      }
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
    expect(m.throttled, isFalse);
    final slowed = VpsMember.fromJson({'throttled': true, 'limit_mbps': 2.5});
    expect(slowed.throttled, isTrue);
    expect(slowed.limitMbps, 2.5);
    expect(VpsMember.fromJson({'throttled': 1, 'limit_mbps': -1}).limitMbps, 0);
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
    expect(r.installerFor('android')!.path, endsWith('android.apk'));
    // #67: no Linux installer; the link is the Windows one, nothing to open.
    expect(r.installerFor('linux'), isNull);
    expect(r.pageFor('linux'), isNull);
    expect(r.pageFor('windows'), isNull);
    expect(r.files.containsKey('bad'), isFalse);
    final onlyFiles = VpsClientRelease.fromJson({
      'version': '2.0.0',
      'files': {'windows': 'https://panel/x.exe'},
    })!;
    expect(onlyFiles.url.toString(), 'https://panel/x.exe');
  });

  test('a release page is opened, never fetched as an installer (#67)', () {
    final page = VpsClientRelease(
      version: '1.0.9',
      url: Uri.parse(
        'https://github.com/xydadada/vps2vpn-client/releases/latest',
      ),
    );
    for (final os in ['windows', 'android', 'macos', 'linux']) {
      expect(page.installerFor(os), isNull, reason: os);
      expect(page.pageFor(os), page.url, reason: os);
    }
    // One direct, versioned link (an older panel): an installer for its own
    // platform only.
    final direct = VpsClientRelease(
      version: '1.0.9',
      url: Uri.parse('https://panel/d/vps2vpn-1.0.9-windows-amd64-setup.exe'),
    );
    expect(direct.installerFor('windows'), direct.url);
    expect(direct.installerFor('android'), isNull);
    expect(direct.pageFor('android'), isNull);
    final apk = VpsClientRelease(
      version: '1.0.9',
      url: Uri.parse('https://panel/d/vps2vpn-1.0.9-android-arm64-v8a.apk'),
    );
    expect(apk.installerFor('android'), apk.url);
    expect(apk.installerFor('windows'), isNull);
    // A file map without this platform falls back to a page link.
    final mixed = VpsClientRelease(
      version: '1.0.9',
      url: Uri.parse('https://example.com/download'),
      files: {
        'windows': Uri.parse(
          'https://panel/d/vps2vpn-1.0.9-windows-amd64-setup.exe',
        ),
      },
    );
    expect(mixed.installerFor('linux'), isNull);
    expect(mixed.pageFor('linux'), mixed.url);
    expect(mixed.pageFor('windows'), isNull);
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

  test(
    'a report the panel cannot take directly goes through our proxy',
    () async {
      // Nothing listens on the panel's port, as when its address is blocked.
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = closed.port;
      await closed.close();
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      final seen = <(String, String?, Object?)>[];
      proxy.listen((req) async {
        seen.add((
          '${req.uri}',
          req.headers.value(HttpHeaders.proxyAuthorizationHeader),
          jsonDecode(await utf8.decodeStream(req)),
        ));
        req.response.statusCode = HttpStatus.ok;
        await req.response.close();
      });
      final base = vpsApiBase(
        'http://127.0.0.1:$deadPort/s/$_tok',
      )!.replace(scheme: 'http');

      expect(
        await reportLine(base, line: 'reality', ok: false, host: '1.2.3.4'),
        isFalse,
      );
      expect(
        await reportLine(
          base,
          line: 'reality',
          ok: false,
          host: '1.2.3.4',
          proxyPort: proxy.port,
          // Sent as typed: the proxy never percent-decodes it.
          proxyAuth: 'u@home:p%@:ss',
        ),
        isTrue,
      );
      expect(seen, hasLength(1));
      expect(seen.single.$1, 'http://127.0.0.1:$deadPort/s/$_tok/api/report');
      expect(
        seen.single.$2,
        'Basic ${base64Encode(utf8.encode('u@home:p%@:ss'))}',
      );
      expect(seen.single.$3, {
        'line': 'reality',
        'ok': false,
        'host': '1.2.3.4',
      });
    },
  );

  test('a subscription with no Hysteria entry still pins the panel', () {
    final pin = 'ab' * 32;
    final other = 'cd' * 32;
    // A disabled account: no proxies, only the panel's own pin.
    expect(
      vpsPinsFromProfile(
        '{"x-vps2vpn-pin": "$pin", "proxies": [], "rules": ["MATCH,REJECT"]}',
        'panel.example',
      ),
      {pin},
    );
    // Entries count only on the panel's host; junk pins are ignored.
    expect(
      vpsPinsFromProfile('''
x-vps2vpn-pin: not-a-pin
proxies:
  - {name: a, type: hysteria2, server: Panel.Example, fingerprint: "$other"}
  - {name: b, type: hysteria2, server: elsewhere.example, fingerprint: "${'ef' * 32}"}
''', 'panel.example'),
      {other},
    );
    expect(vpsPinsFromProfile(': not yaml : [', 'panel.example'), isEmpty);
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
    'a download cut short is a failed transfer, not a bad signature',
    () async {
      final dir = await Directory.systemTemp.createTemp('v2v-release');
      addTearDown(() => dir.delete(recursive: true));
      final transport = _ShortRelease();
      await HttpOverrides.runZoned(() async {
        await expectLater(
          vpsDownloadRelease(
            Uri.parse(
              'https://panel.invalid/s/$_tok/download/vps2vpn-1.0.3-windows-amd64-setup.exe',
            ),
            dir,
            currentVersion: '1.0.2',
          ),
          throwsA(
            isA<HttpException>().having(
              (e) => e.message,
              'message',
              contains('cut short'),
            ),
          ),
        );
      }, createHttpClient: (_) => _ShortReleaseClient(transport));
      // The signature is never asked for a file that did not arrive whole.
      expect(transport.urls, hasLength(1));
      expect(dir.listSync(), isEmpty);
    },
  );

  test('a failed direct download is tried again through our proxy', () async {
    final dir = await Directory.systemTemp.createTemp('v2v-release');
    addTearDown(() => dir.delete(recursive: true));
    final transport = _ShortRelease();
    final url = Uri.parse(
      'https://panel.invalid/s/$_tok/download/vps2vpn-1.0.3-windows-amd64-setup.exe',
    );
    await HttpOverrides.runZoned(() async {
      await expectLater(
        vpsDownloadRelease(url, dir, currentVersion: '1.0.2', proxyPort: 7897),
        throwsA(isA<HttpException>()),
      );
    }, createHttpClient: (_) => _ShortReleaseClient(transport));
    expect(transport.routes, ['DIRECT', 'PROXY 127.0.0.1:7897']);
    expect(dir.listSync(), isEmpty);
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

/// Declares 10 bytes and sends 4, as a connection that drops part way.
class _ShortRelease {
  final urls = <Uri>[];
  final routes = <String?>[];
}

class _ShortReleaseClient implements HttpClient {
  _ShortReleaseClient(this.transport);
  final _ShortRelease transport;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    transport.urls.add(url);
    transport.routes.add(findProxy?.call(url));
    return _ShortReleaseRequest();
  }

  @override
  String Function(Uri url)? findProxy;

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ShortReleaseRequest implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _ShortReleaseResponse();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ShortReleaseResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => 10;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value([1, 2, 3, 4]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
