import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fl_clash/vps2vpn/devices.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Sent = ({String path, Map<String, Object?>? body, Map headers});

VpsDeviceCall _panel(
  List<_Sent> sent,
  (int, String) Function(String path) answer,
) => (path, {body, headers = const {}}) async {
  sent.add((path: path, body: body, headers: headers));
  final (code, text) = answer(path);
  return (code, text, null);
};

const _off = (503, '{"code":"feature_off"}');

void main() {
  final base = Uri.parse(
    'https://panel.example.com:8443/s/OldToken0123456789/api/',
  );

  test('the device id is a lowercase v4 UUID made once', () async {
    final store = <String, String>{};
    vpsDeviceLoad = (key) async => store[key];
    vpsDeviceSave = (key, value) async => store[key] = value;
    final id = vpsNewDeviceId(Random(1));
    expect(
      id,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    final first = await vpsDeviceId();
    expect(store['Id'], first);
    expect(await vpsDeviceId(), first);
  });

  test('the check-in body keeps to what the panel takes', () {
    final body = vpsCheckInBody(
      id: 'id',
      version: '1.0.31',
      name: vpsDeviceName(host: 'x' * 60, platform: 'windows'),
      platform: 'windows',
    );
    expect(body['platform'], 'windows');
    expect((body['name']! as String).length, 40);
    expect(vpsDeviceName(host: 'localhost', platform: 'android'), 'Android');
    expect(
      VpsMember.fromJson({
        'features': {'devices': true},
      }).devices,
      isTrue,
    );
    expect(VpsMember.fromJson({}).devices, isFalse);
  });

  group('check-in', () {
    Future<(VpsDeviceOutcome, List<bool>, int)> beat(
      (int, String) answer,
    ) async {
      final marks = <bool>[];
      var disconnects = 0;
      final sent = <_Sent>[];
      final outcome = await vpsDeviceBeat(
        call: _panel(sent, (_) => answer),
        body: {'device_id': 'me'},
        mark: marks.add,
        disconnect: () => disconnects++,
      );
      expect(sent.single.path, 'device');
      return (outcome, marks, disconnects);
    }

    test('a removed device is marked and disconnected', () async {
      final (outcome, marks, disconnects) = await beat((
        200,
        '{"ok":true,"revoked":true}',
      ));
      expect(outcome, VpsDeviceOutcome.ok);
      expect(marks, [true]);
      expect(disconnects, 1);
    });

    test('a restored device is unmarked and stays connected', () async {
      final (_, marks, disconnects) = await beat((
        200,
        '{"ok":true,"revoked":false}',
      ));
      expect(marks, [false]);
      expect(disconnects, 0);
    });

    test('the feature switched off clears the mark', () async {
      final (outcome, marks, disconnects) = await beat(_off);
      expect(outcome, VpsDeviceOutcome.featureOff);
      expect(marks, [false]);
      expect(disconnects, 0);
    });

    test('a rate limit or no network changes nothing', () async {
      for (final answer in [(429, ''), (502, 'Bad Gateway')]) {
        final (_, marks, disconnects) = await beat(answer);
        expect(marks, isEmpty);
        expect(disconnects, 0);
      }
    });

    test('the mark is kept per subscription and survives a restart', () async {
      String? stored;
      vpsRemovedLoad = () async => stored;
      vpsRemovedSave = (value) async => stored = value;
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(vpsRemovedProvider.notifier).mark(3, true);
      await Future<void>.delayed(Duration.zero);
      expect(jsonDecode(stored!), [3]);
      final again = ProviderContainer();
      addTearDown(again.dispose);
      again.read(vpsRemovedProvider);
      await Future<void>.delayed(Duration.zero);
      expect(again.read(vpsRemovedProvider), {3});
    });
  });

  test('the list says which device is this one', () async {
    final sent = <_Sent>[];
    final list = await vpsListDevices(
      _panel(
        sent,
        (_) => (
          200,
          jsonEncode({
            'devices': [
              {
                'device_id': 'a',
                'name': 'PC',
                'platform': 'windows',
                'last_seen': 1800000000,
                'ip': '203.0.x.x',
                'this_device': true,
              },
              {'device_id': 'b', 'name': 'Phone', 'revoked': true},
              {'name': 'no id'},
            ],
            'online_ips': 2,
            'max_ips': 3,
          }),
        ),
      ),
      'a',
    );
    expect(sent.single.headers, {'X-V2V-Device': 'a'});
    expect(list.devices.map((d) => d.id), ['a', 'b']);
    expect(list.devices.first.thisDevice, isTrue);
    expect(list.devices.last.revoked, isTrue);
    expect((list.onlineIps, list.maxIps), (2, 3));
    final off = await vpsListDevices(_panel([], (_) => _off), 'a');
    expect(off.outcome, VpsDeviceOutcome.featureOff);
    expect(off.devices, isEmpty);
  });

  test('remove and restore post to the device', () async {
    final sent = <_Sent>[];
    final call = _panel(
      sent,
      (p) => p.contains('gone') ? (404, '{}') : (200, '{"ok":true}'),
    );
    expect(
      await vpsSetDeviceRemoved(call, 'b', removed: true),
      VpsDeviceOutcome.ok,
    );
    expect(
      await vpsSetDeviceRemoved(call, 'b', removed: false),
      VpsDeviceOutcome.ok,
    );
    expect(
      await vpsSetDeviceRemoved(call, 'gone', removed: true),
      VpsDeviceOutcome.notFound,
    );
    expect(sent.map((s) => s.path), [
      'devices/b/revoke',
      'devices/b/unrevoke',
      'devices/gone/revoke',
    ]);
    expect(sent.first.body, isNotNull);
  });

  group('sign out every other device', () {
    const fresh = 'https://panel.example.com:8443/s/NewToken0123456789/';

    test('the new link is taken on and fetched', () async {
      final sent = <_Sent>[];
      final adopted = <String>[];
      var fetched = 0;
      final r = await vpsKickOthers(
        call: _panel(
          sent,
          (_) => (
            200,
            jsonEncode({
              'ok': true,
              'sub_url': fresh,
              'base': '/s/NewToken0123456789/',
            }),
          ),
        ),
        base: base,
        ownId: 'me',
        adopt: adopted.add,
        refetch: () async => fetched++,
      );
      expect(sent.single.path, 'devices/kick-others');
      expect(sent.single.body, {'device_id': 'me'});
      expect(r.outcome, VpsDeviceOutcome.ok);
      expect(r.switched, isTrue);
      expect(r.link, fresh);
      expect(adopted, [fresh]);
      expect(fetched, 1);
    });

    test('a fetch that fails leaves this device on the new link', () async {
      final adopted = <String>[];
      final r = await vpsKickOthers(
        call: _panel(
          [],
          (_) => (200, jsonEncode({'ok': true, 'sub_url': fresh})),
        ),
        base: base,
        ownId: 'me',
        adopt: adopted.add,
        refetch: () async => throw const SocketException('down'),
      );
      expect(adopted, [fresh]);
      expect(r.link, fresh);
      expect(r.switched, isFalse);
    });

    test('a link on another host is not taken; base is used instead', () async {
      final adopted = <String>[];
      await vpsKickOthers(
        call: _panel(
          [],
          (_) => (
            200,
            jsonEncode({
              'ok': true,
              'sub_url': 'https://elsewhere.example.net/s/NewToken0123456789/',
              'base': '/s/NewToken0123456789/',
            }),
          ),
        ),
        base: base,
        ownId: 'me',
        adopt: adopted.add,
        refetch: () async {},
      );
      expect(adopted, [fresh]);
      final none = await vpsKickOthers(
        call: _panel([], (_) => (200, '{"ok":true}')),
        base: base,
        ownId: 'me',
        adopt: adopted.add,
        refetch: () async {},
      );
      expect(none.outcome, VpsDeviceOutcome.rejected);
      expect(adopted, hasLength(1));
    });

    test(
      'a refusal, a limit or the switch off leaves the link alone',
      () async {
        for (final (answer, outcome) in [
          (_off, VpsDeviceOutcome.featureOff),
          ((429, ''), VpsDeviceOutcome.rateLimited),
          ((404, '{"code":"not_found"}'), VpsDeviceOutcome.notFound),
        ]) {
          final r = await vpsKickOthers(
            call: _panel([], (_) => answer),
            base: base,
            ownId: 'me',
            adopt: (_) => fail('no new link'),
            refetch: () async => fail('nothing to fetch'),
          );
          expect(r.outcome, outcome);
          expect(r.link, isNull);
        }
      },
    );
  });
}
