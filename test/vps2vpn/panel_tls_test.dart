import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter_test/flutter_test.dart';

const _token = 'AbCdEf0123456789xyzQ';

class _TrustEverything extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (_, _, _) => true;
  }
}

void main() {
  late HttpServer server;
  late String fingerprint;
  final requests = <String>[];
  final reports = <Object?>[];

  setUp(() async {
    requests.clear();
    reports.clear();
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
        requests.add(request.uri.path);
        if (request.uri.path == '/s/$_token/api/report') {
          reports.add(jsonDecode(await utf8.decodeStream(request)));
          request.response.write('{"ok":true}');
        } else {
          request.response.write('{"name":"Pinned member","enabled":true}');
        }
        await request.response.close();
      },
      onError: (Object _) {
        // Pin rejection deliberately aborts the TLS handshake.
      },
    );
  });

  tearDown(() => server.close(force: true));

  Uri base() =>
      vpsApiBase('http://127.0.0.1:${server.port}/s/$_token?format=clash')!;

  test(
    'upgrades the subscription URL and pins member and report requests',
    () async {
      expect(base().scheme, 'https');
      expect(base().port, server.port);
      final member = await fetchMember(base(), certificatePins: {fingerprint});
      expect(member?.member?.name, 'Pinned member');
      expect(
        await reportLine(
          base(),
          line: 'hy2',
          ok: false,
          host: '127.0.0.1',
          certificatePins: {fingerprint},
        ),
        isTrue,
      );
      expect(requests, ['/s/$_token/api/me', '/s/$_token/api/report']);
      expect(reports, [
        {'line': 'hy2', 'ok': false, 'host': '127.0.0.1'},
      ]);
    },
  );

  test('a wrong pin never sends the bearer token request', () async {
    expect(
      (await fetchMember(base(), certificatePins: {'00' * 32}))?.problem,
      VpsPanelProblem.unreachable,
    );
    expect(requests, isEmpty);
  });

  test(
    'no pin requires PKI even when the global override trusts everything',
    () async {
      final result = await HttpOverrides.runWithHttpOverrides(
        () => fetchMember(base()),
        _TrustEverything(),
      );
      expect(result?.problem, VpsPanelProblem.unreachable);
      expect(requests, isEmpty);
    },
  );

  test('a wrong pin cannot be bypassed by the global override', () async {
    final result = await HttpOverrides.runWithHttpOverrides(
      () => fetchMember(base(), certificatePins: {'00' * 32}),
      _TrustEverything(),
    );
    expect(result?.problem, VpsPanelProblem.unreachable);
    expect(requests, isEmpty);
  });
}
