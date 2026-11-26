import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
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
    var writable = false;
    final realLoad = vpsDeviceLoad;
    final realSave = vpsDeviceSave;
    addTearDown(() {
      vpsDeviceLoad = realLoad;
      vpsDeviceSave = realSave;
    });
    vpsDeviceLoad = (_) async => throw const FileSystemException('unavailable');
    await expectLater(vpsDeviceId(), throwsA(isA<FileSystemException>()));
    vpsDeviceLoad = (key) async => store[key];
    vpsDeviceSave = (key, value) async {
      store[key] = value;
      if (!writable) throw const FileSystemException('disk full');
    };
    await expectLater(vpsDeviceId(), throwsA(isA<FileSystemException>()));
    await expectLater(vpsDeviceId(), throwsA(isA<FileSystemException>()));
    writable = true;
    store.clear();
    final loaded = Completer<void>();
    var reads = 0;
    var writes = 0;
    vpsDeviceLoad = (key) async {
      reads++;
      await loaded.future;
      return store[key];
    };
    vpsDeviceSave = (key, value) async {
      writes++;
      store[key] = value;
    };
    final id = vpsNewDeviceId(Random(1));
    expect(
      id,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    final pending = [for (var i = 0; i < 10; i++) vpsDeviceId()];
    loaded.complete();
    final ids = await Future.wait(pending);
    final first = ids.first;
    expect(ids.toSet(), {first});
    expect(reads, 1);
    expect(writes, 1);
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
    const old = 'https://panel.example.com:8443/s/OldToken0123456789';
    final answered = (
      200,
      jsonEncode({
        'ok': true,
        'sub_url': fresh,
        'base': '/s/NewToken0123456789/',
      }),
    );
    Future<void> noWait(Duration _) async {}

    Future<VpsKickResult> kick(
      VpsDeviceCall call, {
      List<String>? adopted,
      Future<void> Function()? refetch,
      bool resumed = false,
    }) => vpsKickOthers(
      call: call,
      base: base,
      ownId: 'me',
      requestId: 'Rq_0123456789abcdefghij',
      resumed: resumed,
      wait: noWait,
      adopt: adopted?.add ?? (_) => fail('no new link'),
      refetch: refetch ?? () async {},
    );

    test('a request id is 128 random bits the panel takes', () {
      final id = vpsNewRequestId(Random(7));
      expect(id, matches(RegExp(r'^[A-Za-z0-9_-]{22,128}$')));
      expect(id, hasLength(22));
      expect(vpsNewRequestId(), isNot(vpsNewRequestId()));
    });

    test('the new link is taken on and fetched', () async {
      final sent = <_Sent>[];
      final adopted = <String>[];
      var fetched = 0;
      final r = await kick(
        _panel(sent, (_) => answered),
        adopted: adopted,
        refetch: () async => fetched++,
      );
      expect(sent.single.path, 'devices/kick-others');
      expect(sent.single.body, {
        'device_id': 'me',
        'request_id': 'Rq_0123456789abcdefghij',
      });
      expect(r.outcome, VpsDeviceOutcome.ok);
      expect(r.switched, isTrue);
      expect(r.link, fresh);
      expect(adopted, [fresh]);
      expect(fetched, 1);
    });

    test('a fetch that fails leaves this device on the new link', () async {
      final adopted = <String>[];
      final r = await kick(
        _panel([], (_) => answered),
        adopted: adopted,
        refetch: () async => throw const SocketException('down'),
      );
      expect(adopted, [fresh]);
      expect(r.link, fresh);
      expect(r.switched, isFalse);
    });

    test(
      'no answer is sent again with the same id, and the replay is taken',
      () async {
        final sent = <_Sent>[];
        var tries = 0;
        final adopted = <String>[];
        final r = await kick((path, {body, headers = const {}}) async {
          sent.add((path: path, body: body, headers: headers));
          if (++tries < 3) throw const SocketException('timed out');
          return (
            200,
            jsonEncode({'ok': true, 'sub_url': fresh, 'replayed': true}),
            null,
          );
        }, adopted: adopted);
        expect(sent, hasLength(3));
        expect(sent.map((s) => s.body!['request_id']).toSet(), {
          'Rq_0123456789abcdefghij',
        });
        expect(r.outcome, VpsDeviceOutcome.ok);
        expect(adopted, [fresh]);
      },
    );

    test('a 404 to a resend means it may have gone through', () async {
      var tries = 0;
      final r = await kick((path, {body, headers = const {}}) async {
        if (++tries == 1) throw const SocketException('timed out');
        return (404, 'Not Found', null);
      });
      expect(tries, 2);
      expect(r.outcome, VpsDeviceOutcome.maybeDone);
      expect(r.link, isNull);
      final resumed = await kick(_panel([], (_) => (404, '')), resumed: true);
      expect(resumed.outcome, VpsDeviceOutcome.maybeDone);
    });

    test('no answer at all stops after three retries', () async {
      var tries = 0;
      final r = await kick((path, {body, headers = const {}}) async {
        tries++;
        throw const SocketException('timed out');
      });
      expect(tries, 4);
      expect(r.outcome, VpsDeviceOutcome.unreachable);
      expect(r.link, isNull);
    });

    test('a link on another host is not taken; base is used instead', () async {
      final adopted = <String>[];
      await kick(
        _panel(
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
        adopted: adopted,
      );
      expect(adopted, [fresh]);
      final none = await kick(_panel([], (_) => (200, '{"ok":true}')));
      expect(none.outcome, VpsDeviceOutcome.rejected);
    });

    test(
      'a refusal, a limit or the switch off leaves the link alone',
      () async {
        for (final (answer, outcome) in [
          (_off, VpsDeviceOutcome.featureOff),
          ((429, ''), VpsDeviceOutcome.rateLimited),
          ((400, '{"code":"bad_request"}'), VpsDeviceOutcome.rejected),
          ((404, '{"code":"not_found"}'), VpsDeviceOutcome.notFound),
        ]) {
          final r = await kick(_panel([], (_) => answer));
          expect(r.outcome, outcome);
          expect(r.link, isNull);
        }
      },
    );

    group('kept on disk', () {
      late Map<String, String> store;
      setUp(() {
        store = {};
        vpsDeviceLoad = (key) async => store[key];
        vpsDeviceSave = (key, value) async => store[key] = value;
      });

      Profile profile() => const Profile(
        id: 9,
        type: ProfileType.url,
        url: old,
        autoUpdateDuration: Duration(hours: 1),
      );

      test('no request is sent without a saved recovery record', () async {
        vpsDeviceSave = (_, _) async =>
            throw const FileSystemException('disk full');
        for (final resume in <VpsKickPending?>[
          null,
          (
            profileId: 9,
            oldUrl: old,
            requestId: 'saved-in-memory',
            at: DateTime.now(),
          ),
        ]) {
          final result = await vpsRunKick(
            call: (path, {body, headers = const {}}) async =>
                fail('no saved replay'),
            profile: profile(),
            put: (_) async => fail('no server request'),
            update: (_) async => fail('no server request'),
            resume: resume,
            wait: noWait,
          );
          expect(result!.outcome, VpsDeviceOutcome.notSaved);
          expect(result.link, isNull);
        }
      });

      test(
        'the new URL is durable before refetch or clearing the replay',
        () async {
          final saving = Completer<void>();
          final saved = Completer<void>();
          var fetched = false;
          final result = vpsRunKick(
            call: _panel([], (_) => answered),
            profile: profile(),
            put: (moved) async {
              expect(moved.url, fresh);
              saving.complete();
              await saved.future;
            },
            update: (_) async => fetched = true,
            wait: noWait,
          );
          await saving.future;
          expect(fetched, isFalse);
          expect(await vpsLoadKickPending(), isNotNull);
          saved.complete();
          expect((await result)!.switched, isTrue);
          expect(fetched, isTrue);
          expect(await vpsLoadKickPending(), isNull);
        },
      );

      test(
        'a failed local save keeps the same kick replay for recovery',
        () async {
          final sent = <_Sent>[];
          final first = await vpsRunKick(
            call: _panel(sent, (_) => answered),
            profile: profile(),
            put: (_) async => throw const FileSystemException('disk full'),
            update: (_) async => fail('URL was not persisted'),
            wait: noWait,
          );
          expect(first!.outcome, VpsDeviceOutcome.notSaved);
          final pending = await vpsLoadKickPending();
          expect(pending, isNotNull);
          final resumed = await vpsRunKick(
            call: _panel(sent, (_) => answered),
            profile: profile(),
            put: (_) async {},
            update: (_) async {},
            resume: pending,
            wait: noWait,
          );
          expect(resumed!.switched, isTrue);
          expect(sent.map((s) => s.body!['request_id']).toSet(), {
            pending!.requestId,
          });
          expect(await vpsLoadKickPending(), isNull);
        },
      );

      test(
        'what got no answer waits, and a restart sends the same id',
        () async {
          final first = <_Sent>[];
          final r = await vpsRunKick(
            call: (path, {body, headers = const {}}) async {
              first.add((path: path, body: body, headers: headers));
              throw const SocketException('down');
            },
            profile: profile(),
            put: (_) async => fail('no new link'),
            update: (_) async => fail('nothing to fetch'),
            wait: noWait,
          );
          expect(r!.outcome, VpsDeviceOutcome.unreachable);
          final pending = await vpsLoadKickPending();
          expect(pending!.profileId, 9);
          expect(pending.oldUrl, old);
          expect(pending.requestId, first.first.body!['request_id']);

          final put = <Profile>[];
          final again = <_Sent>[];
          final resumed = await vpsRunKick(
            call: _panel(again, (_) => answered),
            profile: profile(),
            put: (profile) async => put.add(profile),
            update: (_) async {},
            resume: pending,
            wait: noWait,
          );
          expect(again.single.body!['request_id'], pending.requestId);
          expect(resumed!.link, fresh);
          expect(put.single.url, fresh);
          expect(await vpsLoadKickPending(), isNull);
        },
      );

      test('an answer, even a refusal, clears what waited', () async {
        await vpsRunKick(
          call: _panel([], (_) => (400, '{"code":"bad_request"}')),
          profile: profile(),
          put: (_) async => fail('no new link'),
          update: (_) async {},
          wait: noWait,
        );
        expect(await vpsLoadKickPending(), isNull);
      });
    });
  });
}
