import 'package:fl_clash/vps2vpn/crash_restart.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a Core that keeps dying is restarted only a few times', () {
    final start = DateTime(2026, 11, 23, 12);
    var now = start;
    final restarts = VpsCrashRestarts(now: () => now);
    for (var minute = 0; minute < 3; minute++) {
      now = start.add(Duration(minutes: minute));
      expect(restarts.take(), isTrue, reason: 'crash at minute $minute');
    }
    expect(restarts.take(), isFalse);
    now = start.add(const Duration(minutes: 4, seconds: 59));
    expect(restarts.take(), isFalse);
    // Once the first crash is five minutes old, one more restart fits.
    now = start.add(const Duration(minutes: 5));
    expect(restarts.take(), isTrue);
    expect(restarts.take(), isFalse);
  });
}
