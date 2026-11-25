import 'dart:io';

import 'package:fl_clash/vps2vpn/local_network.dart';
import 'package:flutter_test/flutter_test.dart';

VpsNic _card(String name, List<String> addresses) =>
    (name: name, addresses: [for (final a in addresses) InternetAddress(a)]);

void main() {
  test('only our own adapter or a link-local address is no network', () {
    expect(
      vpsHasOwnAddress([
        _card('vps2vpn', ['198.18.0.1']),
      ]),
      isFalse,
    );
    expect(
      vpsHasOwnAddress([
        _card('Ethernet', ['169.254.7.9']),
      ]),
      isFalse,
    );
    expect(
      vpsHasOwnAddress([
        _card('WLAN', ['fe80::1']),
      ]),
      isFalse,
    );
    expect(
      vpsHasOwnAddress([
        _card('vps2vpn', ['198.18.0.1']),
        _card('WLAN', ['192.0.2.20']),
      ]),
      isTrue,
    );
  });

  test("Windows' verdict, our adapter aside", () {
    VpsLocalNet read(String lines, {bool viaTun = false}) =>
        vpsReadConnectivity(lines, viaTun: viaTun);

    expect(read('vps2vpn|InternetAccess\nWLAN|None\n'), VpsLocalNet.offline);
    expect(read('WLAN|None\nWLAN|InternetAccess\n'), VpsLocalNet.online);
    expect(read('WLAN|ConstrainedInternetAccess\n'), VpsLocalNet.portal);
    expect(read('WLAN|LocalAccess\n'), VpsLocalNet.offline);
    expect(read('WLAN|LocalAccess\n', viaTun: true), VpsLocalNet.unknown);
    expect(read(''), VpsLocalNet.unknown);
  });

  test(
    'no card with an address answers at once, without asking Windows',
    () async {
      var asked = false;
      final verdict = await vpsCheckLocalNetwork(
        viaTun: true,
        cards: () async => [
          _card('vps2vpn', ['198.18.0.1']),
        ],
        connectivity: () async {
          asked = true;
          return 'WLAN|InternetAccess';
        },
      );
      expect(verdict, VpsLocalNet.offline);
      expect(asked, isFalse);
    },
  );

  test(
    'a check that fails leaves the line to blame, not the network',
    () async {
      final verdict = await vpsCheckLocalNetwork(
        viaTun: false,
        cards: () async => [
          _card('WLAN', ['192.0.2.20']),
        ],
        connectivity: () async =>
            throw const ProcessException('powershell', []),
      );
      expect(verdict, VpsLocalNet.unknown);
    },
  );

  test('Windows saying offline is overruled by a direct answer', () async {
    Future<VpsLocalNet> check({required bool viaTun, required bool answers}) =>
        vpsCheckLocalNetwork(
          viaTun: viaTun,
          cards: () async => [
            _card('WLAN', ['192.0.2.20']),
          ],
          connectivity: () async => 'WLAN|None',
          reaches: () async => answers,
        );

    expect(await check(viaTun: false, answers: true), VpsLocalNet.unknown);
    expect(await check(viaTun: false, answers: false), VpsLocalNet.offline);
    expect(await check(viaTun: true, answers: true), VpsLocalNet.offline);
  });
}
