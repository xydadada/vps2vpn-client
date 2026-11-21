import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class FlClashHttpOverrides extends HttpOverrides {
  final ProviderContainer _container;

  FlClashHttpOverrides(this._container);

  static const _coreRootsAsset =
      'core/Clash.Meta/component/ca/ca-certificates.crt';

  /// The bundle the core embeds; only release CI fills it.
  static Future<void> trustCoreRoots() async {
    try {
      final data = await rootBundle.load(_coreRootsAsset);
      if (data.lengthInBytes == 0) return;
      SecurityContext.defaultContext.setTrustedCertificatesBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } catch (e) {
      commonPrint.log(
        'trustCoreRoots error ${compactError(e)}',
        logLevel: LogLevel.warning,
      );
    }
  }

  static String findProxyFor(ProviderContainer container, Uri url) {
    return findProxyForReader(container.read, url);
  }

  /// Local helper and diagnostics traffic must never be sent back into the
  /// proxy. 127.0.0.0/8 is *all* loopback, not just 127.0.0.1.
  static bool _isLoopbackHost(String host) {
    var name = host.toLowerCase();
    // A terminal dot is legal FQDN spelling for a loopback hostname or
    // numeric IPv4 address, and must not cause the request to proxy itself.
    while (name.endsWith('.')) {
      name = name.substring(0, name.length - 1);
    }
    if (name == 'localhost' || name.endsWith('.localhost')) {
      return true;
    }
    // Numeric parsing is synchronous and never performs DNS resolution.
    return InternetAddress.tryParse(name)?.isLoopback ?? false;
  }

  static String findProxyForReader(ProviderReader read, Uri url) {
    if (_isLoopbackHost(url.host)) {
      return 'DIRECT';
    }
    final isStart = read(isStartProvider);
    final suspend = read(suspendProvider);
    if (!isStart || suspend) return 'DIRECT';
    final mixedPort = read(
      patchClashConfigProvider.select((state) => state.mixedPort),
    );
    return 'PROXY 127.0.0.1:$mixedPort';
  }

  static bool allowBadCertificate(
    ProviderContainer container,
    X509Certificate certificate,
    String host,
    int port,
  ) {
    return allowBadCertificateForReader(
      container.read,
      certificate,
      host,
      port,
    );
  }

  static bool allowBadCertificateForReader(
    ProviderReader read,
    X509Certificate certificate,
    String host,
    int port,
  ) {
    final checkCertificate = read(
      appSettingProvider.select((state) => state.checkCertificate),
    );
    commonPrint.log(
      'untrusted certificate for $host:$port issued by ${certificate.issuer}, '
      'check: $checkCertificate',
      logLevel: LogLevel.warning,
    );
    return !checkCertificate;
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (certificate, host, port) =>
        allowBadCertificate(_container, certificate, host, port);
    client.findProxy = (url) => findProxyFor(_container, url);
    // PAC proxy strings do not percent-decode userinfo. Preinstall Basic
    // credentials to preserve upload bodies: a 407 retry discards the body
    // of an already streamed PUT in Dart's HttpClient implementation.
    final mixedPort = _container.read(
      patchClashConfigProvider.select((state) => state.mixedPort),
    );
    final authentication = _container.read(
      networkSettingProvider.select((state) => state.authentication),
    );
    if (authentication.enable && authentication.username.isNotEmpty) {
      client.addProxyCredentials(
        '127.0.0.1',
        mixedPort,
        '',
        HttpClientBasicCredentials(
          authentication.username,
          authentication.password,
        ),
      );
    }
    return client;
  }
}
