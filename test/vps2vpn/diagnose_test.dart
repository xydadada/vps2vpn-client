import 'dart:io';

import 'package:fl_clash/vps2vpn/diagnose.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one bare address that answers means the network is up', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((client) => client.destroy());
    final dialled = <String>[];
    final up = await vpsReachesInternet(
      connect: (host, port, timeout) {
        dialled.add(host);
        if (host == '1.1.1.1') {
          return Socket.connect(InternetAddress.loopbackIPv4, server.port);
        }
        return Future.error(const SocketException('unreachable'));
      },
    );
    expect(up, isTrue);
    expect(dialled, everyElement(matches(RegExp(r'^[\d.]+$'))));
  });

  test('no bare address answering means the network is down', () async {
    final up = await vpsReachesInternet(
      connect: (host, port, timeout) =>
          Future.error(const SocketException('unreachable')),
    );
    expect(up, isFalse);
  });
}
