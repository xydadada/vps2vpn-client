import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/http.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

class _FakeCertificate implements X509Certificate {
  @override
  String get issuer => 'CN=Untrusted';

  @override
  String get subject => 'CN=example.com';

  @override
  DateTime get startValidity => DateTime(2026);

  @override
  DateTime get endValidity => DateTime(2027);

  @override
  Uint8List get der => Uint8List(0);

  @override
  String get pem => '';

  @override
  Uint8List get sha1 => Uint8List(0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer buildContainer({
    bool running = true,
    String? currentSsid,
    List<String> excludeSSIDs = const [],
    int mixedPort = 7890,
    bool checkCertificate = true,
  }) {
    final container = ProviderContainer(
      overrides: [excludeSSIDsProvider.overrideWithValue(excludeSSIDs)],
    );
    addTearDown(container.dispose);
    container.read(runTimeProvider.notifier).value = running ? 1 : null;
    container.read(currentSSIDProvider.notifier).value = currentSsid;
    container.read(patchClashConfigProvider.notifier).value =
        const PatchClashConfig().copyWith(mixedPort: mixedPort);
    container.read(appSettingProvider.notifier).value = const AppSettingProps()
        .copyWith(checkCertificate: checkCertificate);
    return container;
  }

  final remote = Uri.parse('https://example.com/path');

  test('loopback traffic always bypasses the proxy', () {
    final container = buildContainer();

    expect(
      FlClashHttpOverrides.findProxyFor(
        container,
        Uri.parse('http://$localhost:9090/ui'),
      ),
      'DIRECT',
    );
  });

  test('bypasses every IPv4 loopback address and localhost name', () {
    final container = buildContainer(mixedPort: 7891);
    for (final host in [
      '127.0.0.2',
      '127.255.255.254',
      '127.0.0.1.',
      '127.0.0.2.',
      'localhost.',
      'LOCALHOST..',
      'api.localhost..',
      'api.localhost',
      'api.localhost.',
      '[::1]',
    ]) {
      final url = Uri.parse('http://$host:9090/health');
      expect(
        FlClashHttpOverrides.findProxyFor(container, url),
        'DIRECT',
        reason: 'Loopback URL must not be proxied: $url',
      );
    }
    for (final host in ['127.0.0.2.example.com', '192.0.2.1', 'example.com']) {
      final url = Uri.parse('https://$host/status');
      expect(
        FlClashHttpOverrides.findProxyFor(container, url),
        'PROXY 127.0.0.1:7891',
        reason: 'Non-loopback host must keep normal routing: $url',
      );
    }
  });

  test('routes through the mixed port while the core is running', () {
    final container = buildContainer(mixedPort: 7891);

    expect(
      FlClashHttpOverrides.findProxyFor(container, remote),
      'PROXY 127.0.0.1:7891',
    );
  });

  test('authenticated local proxy uses a credential-free PAC directive', () {
    final container = buildContainer();
    container.read(networkSettingProvider.notifier).value = const NetworkProps()
        .copyWith(
          authentication: const AuthenticationProps(
            enable: true,
            username: 'user',
            password: 'pass',
          ),
        );

    expect(
      FlClashHttpOverrides.findProxyFor(container, remote),
      'PROXY 127.0.0.1:7890',
    );

    container.read(networkSettingProvider.notifier).value = const NetworkProps()
        .copyWith(
          authentication: const AuthenticationProps(
            enable: false,
            username: 'user',
          ),
        );
    expect(
      FlClashHttpOverrides.findProxyFor(container, remote),
      'PROXY 127.0.0.1:7890',
    );
  });

  test('actual proxy 407 challenge receives raw punctuation credentials', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    const username = 'user@home';
    const password = 'p%@:ss';
    final container = buildContainer(mixedPort: proxy.port);
    container.read(networkSettingProvider.notifier).value = const NetworkProps()
        .copyWith(authentication: const AuthenticationProps(
          enable: true,
          username: username,
          password: password,
        ));
    final expected = 'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    var challenges = 0;
    final received = <String>[];
    proxy.listen((request) async {
      final credential = request.headers.value(HttpHeaders.proxyAuthorizationHeader);
      if (credential == null) {
        challenges++;
        request.response
          ..statusCode = HttpStatus.proxyAuthenticationRequired
          ..headers.set(HttpHeaders.proxyAuthenticateHeader, 'Basic realm="local-test"');
      } else {
        received.add(credential);
        request.response.statusCode = credential == expected
            ? HttpStatus.ok
            : HttpStatus.forbidden;
      }
      await request.response.close();
    });
    final client = FlClashHttpOverrides(container).createHttpClient(null);
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(
      Uri.parse('http://example.invalid/proxy-check'),
    )).close();
    await response.drain<void>();
    expect(response.statusCode, HttpStatus.ok);
    expect(challenges, 1);
    expect(received, [expected]);
  });

  test('bypasses the proxy when the core is not running', () {
    final container = buildContainer(running: false);

    expect(FlClashHttpOverrides.findProxyFor(container, remote), 'DIRECT');
  });

  test('bypasses the proxy on an excluded SSID', () {
    final container = buildContainer(
      currentSsid: 'Office Wi-Fi',
      excludeSSIDs: const ['Office Wi-Fi'],
    );

    expect(FlClashHttpOverrides.findProxyFor(container, remote), 'DIRECT');
  });

  test('keeps proxying when the current SSID is not excluded', () {
    final container = buildContainer(
      currentSsid: 'Home Wi-Fi',
      excludeSSIDs: const ['Office Wi-Fi'],
    );

    expect(
      FlClashHttpOverrides.findProxyFor(container, remote),
      'PROXY 127.0.0.1:7890',
    );
  });

  test('an untrusted certificate is rejected by default', () {
    final container = buildContainer();

    expect(
      FlClashHttpOverrides.allowBadCertificate(
        container,
        _FakeCertificate(),
        'example.com',
        443,
      ),
      isFalse,
    );
  });

  test('turning the check off accepts an untrusted certificate', () {
    final container = buildContainer(checkCertificate: false);

    expect(
      FlClashHttpOverrides.allowBadCertificate(
        container,
        _FakeCertificate(),
        'example.com',
        443,
      ),
      isTrue,
    );
  });
}
