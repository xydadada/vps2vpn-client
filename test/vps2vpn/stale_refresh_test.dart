import 'package:fl_clash/vps2vpn/stale_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 11, 24, 12);

  test('a dead line fetches a subscription not updated lately', () {
    expect(
      vpsShouldRefresh(
        now: now,
        updatedAt: now.subtract(const Duration(hours: 5)),
        triedAt: null,
      ),
      isTrue,
    );
    expect(vpsShouldRefresh(now: now, updatedAt: null, triedAt: null), isTrue);
  });

  test('not right after an update, and not again within half an hour', () {
    expect(
      vpsShouldRefresh(
        now: now,
        updatedAt: now.subtract(const Duration(minutes: 3)),
        triedAt: null,
      ),
      isFalse,
    );
    expect(
      vpsShouldRefresh(
        now: now,
        updatedAt: now.subtract(const Duration(hours: 5)),
        triedAt: now.subtract(const Duration(minutes: 10)),
      ),
      isFalse,
    );
    expect(
      vpsShouldRefresh(
        now: now,
        updatedAt: now.subtract(const Duration(hours: 5)),
        triedAt: now.subtract(const Duration(minutes: 31)),
      ),
      isTrue,
    );
  });
}
