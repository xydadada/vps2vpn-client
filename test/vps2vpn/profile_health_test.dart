import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/vps2vpn/profile_health.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
  final realRead = vpsReadSnapshot;
  tearDown(() => vpsReadSnapshot = realRead);

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
