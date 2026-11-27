import 'dart:convert';

import 'package:fl_clash/vps2vpn/devices.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (label, reply) in [
    ('invalid JSON', '<html>gateway error</html>'),
    ('array', '[]'),
    ('empty object', '{}'),
    ('missing acknowledgement', '{"revoked":false}'),
    ('rejected acknowledgement', '{"ok":false,"revoked":false}'),
    ('string acknowledgement', '{"ok":"true","revoked":false}'),
    ('missing revoked flag', '{"ok":true}'),
    ('null revoked flag', '{"ok":true,"revoked":null}'),
    ('string revoked flag', '{"ok":true,"revoked":"false"}'),
    ('number revoked flag', '{"ok":true,"revoked":0}'),
    ('unacknowledged removal', '{"ok":false,"revoked":true}'),
  ]) {
    test('a 200 with $label cannot change device state', () async {
      final marks = <bool>[];
      var disconnects = 0;
      final result = await vpsDeviceBeat(
        call: (_, {body, headers = const {}}) async => (200, reply, null),
        body: const {},
        mark: marks.add,
        disconnect: () => disconnects++,
      );
      expect(result, VpsDeviceOutcome.unreachable);
      expect(marks, isEmpty);
      expect(disconnects, 0);
    });
  }

  for (final revoked in [false, true]) {
    test(
      'an acknowledged boolean revoked=$revoked remains compatible',
      () async {
        final marks = <bool>[];
        var disconnects = 0;
        final result = await vpsDeviceBeat(
          call: (_, {body, headers = const {}}) async =>
              (200, jsonEncode({'ok': true, 'revoked': revoked}), null),
          body: const {},
          mark: marks.add,
          disconnect: () => disconnects++,
        );
        expect(result, VpsDeviceOutcome.ok);
        expect(marks, [revoked]);
        expect(disconnects, revoked ? 1 : 0);
      },
    );
  }

  test('a disabled feature is distinct from a successful check-in', () async {
    final marks = <bool>[];
    final result = await vpsDeviceBeat(
      call: (_, {body, headers = const {}}) async =>
          (503, '{"code":"feature_off"}', null),
      body: const {},
      mark: marks.add,
      disconnect: () => fail('no automatic connection change'),
    );
    expect(result, VpsDeviceOutcome.featureOff);
    expect(marks, [false]);
  });
}
