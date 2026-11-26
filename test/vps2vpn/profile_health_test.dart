import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/vps2vpn/profile_health.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import '../helpers/preferences.dart';

class _LoadingStore extends InMemorySharedPreferencesStore {
  _LoadingStore() : super.empty();
  final loading = Completer<Map<String, Object>>();
  final writes = <String, Object>{};

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) => loading.future;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes[key] = value;
    return true;
  }
}

VpsProfileSnapshot _snap(List<String> nodes) => vpsSnapshotOf(
  utf8.encode(
    jsonEncode({
      'proxies': [
        for (final n in nodes) {'name': n, 'type': 'ss'},
      ],
    }),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final realRead = vpsReadSnapshot;
  tearDown(() => vpsReadSnapshot = realRead);

  test(
    'live changes survive late hydration and are saved for restart',
    () async {
      SharedPreferences.resetStatic();
      final store = _LoadingStore();
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(mockPreferences);
      final rebound = preferences.rebind();
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final health = c.read(vpsProfileHealthProvider.notifier);
      health.forget(1);
      health.failed(2, const SocketException('offline'), 'new failure');
      expect(store.writes, isEmpty);
      store.loading.complete({
        'flutter.vpsProfileHealth': jsonEncode({
          '1': const VpsProfileHealth().toJson(),
          '2': const VpsProfileHealth().toJson(),
          '3': const VpsProfileHealth().toJson(),
        }),
      });
      await rebound;
      await Future<void>.delayed(Duration.zero);
      expect(c.read(vpsProfileHealthProvider).keys.toSet(), {2, 3});
      expect(health.of(2)!.error, 'new failure');
      final saved =
          jsonDecode(store.writes['flutter.vpsProfileHealth']! as String)
              as Map;
      expect(saved.keys.toSet(), {'2', '3'});
      expect((saved['2'] as Map)['error'], 'new failure');
      final again = ProviderContainer();
      addTearDown(again.dispose);
      again.read(vpsProfileHealthProvider);
      await Future<void>.delayed(Duration.zero);
      expect(again.read(vpsProfileHealthProvider).keys.toSet(), {2, 3});
      expect(again.read(vpsProfileHealthProvider)[2]!.error, 'new failure');
    },
  );

  test('reads node names from YAML and from our JSON profile', () {
    final yaml = vpsSnapshotOf(
      utf8.encode(
        'proxies:\n  - name: 台湾\n    type: ss\n  - {name: 日本, type: ss}\n',
      ),
    );
    expect(yaml.nodes, ['台湾', '日本']);
    expect(yaml.digest, isNotNull);
    expect(_snap(['A']).nodes, ['A']);
    expect(vpsSnapshotOf(utf8.encode('proxy-providers: {}')).nodes, isNull);
  });

  test(
    'an update says which nodes it added, or that nothing changed',
    () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final health = c.read(vpsProfileHealthProvider.notifier);
      var file = _snap(['台湾', '日本']);
      vpsReadSnapshot = (_) async => file;
      final before = file;
      file = _snap(['台湾', '日本', '洛杉矶', '新台湾']);
      final h = await health.succeeded(1, before);
      expect(h.ok, isTrue);
      expect(h.changed, isTrue);
      expect(h.added, ['洛杉矶', '新台湾']);
      expect(h.isNew('洛杉矶', DateTime.now()), isTrue);
      expect(h.isNew('台湾', DateTime.now()), isFalse);

      final same = await health.succeeded(1, file);
      expect(same.changed, isFalse);
      expect(same.added, ['洛杉矶', '新台湾']);
    },
  );

  test('failures count up from the first and reset on success', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final health = c.read(vpsProfileHealthProvider.notifier);
    const down = SocketException('Connection refused');
    final first = health.failed(7, down, 'x');
    expect(first.unreachable, isTrue);
    expect(first.failures, 1);
    final second = health.failed(7, down, 'x');
    expect(second.failures, 2);
    expect(second.failingSince, first.failingSince);
    expect(second.deadAt(DateTime.now()), isFalse);
    final third = health.failed(7, down, 'x');
    expect(third.deadAt(DateTime.now().add(vpsDeadAfter)), isTrue);

    vpsReadSnapshot = (_) async => _snap(['A']);
    final ok = await health.succeeded(7, _snap(['A']));
    expect(ok.ok, isTrue);
    expect(ok.failures, 0);
  });

  test('only a server out of reach counts as unreachable', () {
    expect(vpsUnreachable(const SocketException('Failed host lookup')), isTrue);
    expect(vpsUnreachable(Exception('connection timed out')), isTrue);
    expect(vpsUnreachable(Exception('HTTP 403 Forbidden')), isFalse);
  });

  test('round-trips through its saved form', () {
    final h = VpsProfileHealth(
      at: DateTime.fromMillisecondsSinceEpoch(1000),
      ok: false,
      error: 'e',
      unreachable: true,
      failingSince: DateTime.fromMillisecondsSinceEpoch(500),
      failures: 3,
      added: const ['A'],
    );
    final back = VpsProfileHealth.fromJson(h.toJson());
    expect(back.failures, 3);
    expect(back.failingSince, h.failingSince);
    expect(back.added, ['A']);
    expect(back.unreachable, isTrue);
  });
}
