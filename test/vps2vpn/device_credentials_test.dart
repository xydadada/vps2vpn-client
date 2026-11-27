import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/database/database.dart' as db;
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/vps2vpn/devices.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _old = 'https://panel.example.test/s/OldSyntheticToken0123456789';
const _fresh = 'https://panel.example.test/s/NewSyntheticToken0123456789';
const _storedId = '12345678-1234-4123-8123-123456789abc';
const _profile = Profile(
  id: 9,
  type: ProfileType.url,
  url: _old,
  autoUpdateDuration: Duration(hours: 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> store;

  setUp(() {
    vpsResetDeviceId();
    store = {};
    vpsDeviceLoad = (key) async => store[key];
    vpsDeviceSave = (key, value) async => store[key] = value;
  });

  tearDown(() {
    vpsResetDeviceId();
    vpsDeviceLoad = preferences.getVpsDevice;
    vpsDeviceSave = preferences.setVpsDevice;
  });

  group('device identity persistence', () {
    test('concurrent callers share one saved identity', () async {
      final read = Completer<String?>();
      final save = Completer<void>();
      var reads = 0;
      var writes = 0;
      vpsDeviceLoad = (_) {
        reads++;
        return read.future;
      };
      vpsDeviceSave = (key, value) async {
        writes++;
        await save.future;
        store[key] = value;
      };
      final calls = [for (var i = 0; i < 10; i++) vpsDeviceId()];
      expect(reads, 1);
      read.complete(null);
      await pumpEventQueue();
      expect(writes, 1);
      expect(store, isEmpty);
      save.complete();
      final ids = await Future.wait(calls);
      expect(ids.toSet(), {store['Id']});
      expect(await vpsDeviceId(), ids.first);
      expect((reads, writes), (1, 1));
    });

    test('a failed initialization can be retried', () async {
      var reads = 0;
      vpsDeviceLoad = (_) async {
        if (++reads == 1) throw StateError('synthetic read failure');
        return null;
      };
      await expectLater(
        Future.wait([vpsDeviceId(), vpsDeviceId()]),
        throwsStateError,
      );
      final id = await vpsDeviceId();
      expect(store['Id'], id);
      expect(reads, 2);
    });

    test('an existing ID does not require another write', () async {
      store['Id'] = _storedId.toUpperCase();
      vpsDeviceSave = (_, _) async => fail('an existing ID needs no write');
      expect(await vpsDeviceId(), _storedId);
    });

    test(
      'a failed new ID save cannot be mistaken for a persisted ID',
      () async {
        var writes = 0;
        final attempted = <String>[];
        vpsDeviceSave = (key, value) async {
          store[key] = value;
          attempted.add(value);
          if (++writes < 3) throw StateError('synthetic write failure');
        };
        await expectLater(vpsDeviceId(), throwsStateError);
        await expectLater(vpsDeviceId(), throwsStateError);
        expect(await vpsDeviceId(), store['Id']);
        expect(await vpsDeviceId(), store['Id']);
        expect(attempted.toSet(), {store['Id']});
        expect(writes, 3);
      },
    );
  });

  group('rotation recovery', () {
    late db.Database database;
    late ProviderContainer container;
    late Profiles profiles;
    late List<Map<String, Object?>> sent;

    setUp(() async {
      database = db.Database(NativeDatabase.memory());
      db.database = database;
      container = ProviderContainer();
      container.listen(profilesProvider, (_, _) {});
      await pumpEventQueue();
      profiles = container.read(profilesProvider.notifier);
      await profiles.putAsync(_profile);
      sent = [];
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    Future<(int, String, String?)> answer(
      String path, {
      Map<String, Object?>? body,
      Map<String, String> headers = const {},
    }) async {
      expect(path, 'devices/kick-others');
      sent.add(body!);
      return (200, jsonEncode({'ok': true, 'sub_url': _fresh}), null);
    }

    Future<VpsKickResult?> run({
      VpsKickPending? resume,
      Future<void> Function(Profile)? update,
    }) => vpsRunKick(
      call: answer,
      profile: _profile,
      put: profiles.putAsync,
      update: update ?? (_) async {},
      resume: resume,
      wait: (_) async {},
    );

    test('the recovery record and fetch wait for the database write', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final held = database.transaction(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      var fetched = false;
      var finished = false;
      final operation =
          run(
            update: (_) async {
              expect((await database.profilesDao.get(9))?.url, _fresh);
              fetched = true;
            },
          ).then((result) {
            finished = true;
            return result;
          });
      try {
        await pumpEventQueue();
        expect(sent, hasLength(1));
        expect(fetched, isFalse);
        expect(finished, isFalse);
        expect((await vpsLoadKickPending())?.oldUrl, _old);
      } finally {
        release.complete();
      }
      await held;
      final result = await operation;
      expect(result?.outcome, VpsDeviceOutcome.ok);
      expect(result?.switched, isTrue);
      expect(fetched, isTrue);
      expect(await vpsLoadKickPending(), isNull);
    });

    test('failed database save keeps the same request for recovery', () async {
      await database.customStatement(
        'CREATE TRIGGER deny_profile_save BEFORE INSERT ON profiles '
        "BEGIN SELECT RAISE(ABORT, 'synthetic write failure'); END",
      );
      final first = await run(update: (_) async => fail('not saved yet'));
      expect(first?.outcome, VpsDeviceOutcome.notSaved);
      expect(first?.link, isNull);
      expect((await database.profilesDao.get(9))?.url, _old);
      expect(container.read(profilesProvider).single.url, _old);
      final pending = await vpsLoadKickPending();
      expect(pending?.requestId, sent.single['request_id']);

      await database.customStatement('DROP TRIGGER deny_profile_save');
      final retried = await run(resume: pending);
      expect(retried?.outcome, VpsDeviceOutcome.ok);
      expect(retried?.link, _fresh);
      expect(sent, hasLength(2));
      expect(sent[1]['request_id'], sent[0]['request_id']);
      expect((await database.profilesDao.get(9))?.url, _fresh);
      expect(await vpsLoadKickPending(), isNull);
    });

    test('a failed recovery-record save sends no request', () async {
      vpsDeviceSave = (_, _) async => throw StateError('synthetic failure');
      final result = await run();
      expect(result?.outcome, VpsDeviceOutcome.notSaved);
      expect(sent, isEmpty);
      expect((await database.profilesDao.get(9))?.url, _old);
    });

    test('a resumed recovery must still have a durable record', () async {
      final pending = (
        profileId: 9,
        oldUrl: _old,
        requestId: 'SyntheticRequest0123456789',
        at: DateTime.now(),
      );
      vpsDeviceSave = (key, value) async {
        store[key] = value;
        throw StateError('synthetic failure');
      };
      final result = await run(resume: pending);
      expect(result?.outcome, VpsDeviceOutcome.notSaved);
      expect(sent, isEmpty);
    });

    test('refetch failure keeps the already persisted new link', () async {
      final result = await run(
        update: (_) async => throw StateError('synthetic download failure'),
      );
      expect(result?.outcome, VpsDeviceOutcome.ok);
      expect(result?.link, _fresh);
      expect(result?.switched, isFalse);
      expect((await database.profilesDao.get(9))?.url, _fresh);
      expect(await vpsLoadKickPending(), isNull);
    });
  });

  for (final reply in [
    (200, '{"ok":true,"revoked":true}'),
    (503, '{"code":"feature_off"}'),
  ]) {
    test(
      'a late ${reply.$1} check-in cannot change a disposed scope',
      () async {
        final response = Completer<(int, String, String?)>();
        var current = true;
        final marks = <bool>[];
        var disconnects = 0;
        final checking = vpsDeviceBeat(
          call: (_, {body, headers = const {}}) => response.future,
          body: const {'device_id': _storedId},
          mark: marks.add,
          disconnect: () => disconnects++,
          isCurrent: () => current,
        );
        current = false;
        response.complete((reply.$1, reply.$2, null));
        await checking;
        expect(marks, isEmpty);
        expect(disconnects, 0);
      },
    );
  }
}
