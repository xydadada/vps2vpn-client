import 'dart:async';

import 'package:fl_clash/vps2vpn/line_watch.dart';
import 'package:flutter_test/flutter_test.dart';

const line = VpsWatchedLine(
  name: 'A',
  kind: 'tuic',
  host: 'a.invalid',
  testUrl: 'https://probe.invalid',
);

void main() {
  test(
    'sustained failures refresh before the panel expires a daily report',
    () {
      final health = VpsLineHealth(threshold: 1);
      var now = DateTime.utc(2026);
      health.record(line.key, false);
      health.complete(health.pending(line.key, now)!, true, now);
      for (var cycle = 0; cycle < 5; cycle++) {
        expect(
          health.pending(line.key, now.add(const Duration(hours: 5))),
          isNull,
        );
        now = now.add(const Duration(hours: 6));
        expect(health.record(line.key, false), isNull);
        final heartbeat = health.pending(line.key, now)!;
        expect(heartbeat.ok, isFalse);
        health.complete(heartbeat, true, now);
      }
      health.record(line.key, true);
      health.complete(health.pending(line.key, now)!, true, now);
      expect(
        health.pending(line.key, now.add(const Duration(days: 2))),
        isNull,
      );
    },
  );

  test('delivery failure and recovery stay pending until acknowledged', () {
    final health = VpsLineHealth();
    final now = DateTime.utc(2026);
    for (var i = 0; i < 3; i++) {
      health.record(line.key, false);
    }
    final down = health.pending(line.key, now)!;
    health.complete(down, false, now);
    expect(
      health.pending(line.key, now.add(const Duration(minutes: 3))),
      isNull,
    );
    expect(
      health.pending(line.key, now.add(const Duration(minutes: 4))),
      same(down),
    );
    health.record(line.key, true);
    final up = health.pending(line.key, now)!;
    health.complete(down, true, now);
    expect(health.pending(line.key, now), same(up));
    health.complete(up, false, now);
    expect(
      health.pending(line.key, now.add(const Duration(minutes: 4))),
      same(up),
    );
    health.complete(up, true, now);
    expect(health.pending(line.key, now), isNull);
  });

  test(
    'overlapping scans coalesce and disposal rejects a late probe',
    () async {
      final started = Completer<void>();
      final answer = Completer<bool>();
      var probes = 0;
      var reports = 0;
      final watch = VpsLineWatch(
        lines: () async => [line],
        probe: (_) async {
          if (++probes < 3) return false;
          started.complete();
          return answer.future;
        },
        report: (_, __) async {
          reports++;
          return true;
        },
      );
      addTearDown(watch.dispose);
      await watch.checkNow();
      await watch.checkNow();
      final run = watch.checkNow();
      await started.future;
      expect(watch.checkNow(), same(run));
      watch.dispose();
      answer.complete(false);
      await run;
      expect(reports, 0);
      await watch.checkNow();
      expect(probes, 3);
    },
  );

  test('different subscriptions never share a failure threshold', () async {
    var reports = 0;
    VpsLineWatch make() => VpsLineWatch(
      lines: () async => [line],
      probe: (_) async => false,
      report: (_, __) async {
        reports++;
        return true;
      },
    );
    final first = make();
    await first.checkNow();
    await first.checkNow();
    first.dispose();
    final second = make();
    addTearDown(second.dispose);
    await second.checkNow();
    expect(reports, 0);
    await second.checkNow();
    await second.checkNow();
    expect(reports, 1);
  });

  test('same server and protocol counts one observation per scan', () async {
    var healthy = true;
    var reports = 0;
    final watch = VpsLineWatch(
      lines: () async => [
        line,
        const VpsWatchedLine(
          name: 'A-other-port',
          kind: 'tuic',
          host: 'a.invalid',
          testUrl: 'https://probe.invalid',
        ),
      ],
      probe: (node) async => healthy && node.name == 'A-other-port',
      report: (_, __) async {
        reports++;
        return true;
      },
    );
    addTearDown(watch.dispose);
    for (var i = 0; i < 4; i++) {
      await watch.checkNow();
    }
    expect(reports, 0);
    healthy = false;
    await watch.checkNow();
    await watch.checkNow();
    expect(reports, 0);
    await watch.checkNow();
    expect(reports, 1);
  });

  test('a probe exception does not starve later servers', () async {
    const later = VpsWatchedLine(
      name: 'B',
      kind: 'tuic',
      host: 'b.invalid',
      testUrl: 'https://probe.invalid',
    );
    final reports = <String>[];
    final watch = VpsLineWatch(
      lines: () async => [line, later],
      probe: (node) async {
        if (node.name == line.name) throw StateError('no Core response');
        return false;
      },
      report: (node, _) async {
        reports.add(node.host);
        return true;
      },
    );
    addTearDown(watch.dispose);
    for (var i = 0; i < 3; i++) {
      await watch.checkNow();
    }
    expect(reports, ['b.invalid']);
  });
}
