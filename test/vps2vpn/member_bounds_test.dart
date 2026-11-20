import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('zero effective quota stays limited when its base quota was finite', () {
    final exhausted = VpsMember.fromJson({
      'name': 'Exhausted',
      'enabled': false,
      'quota_gb': 10,
      'quota_eff': 0,
    });
    expect(exhausted.quotaBytes, 0);
    expect(exhausted.isLimited, isTrue);
    expect(VpsMember.fromJson({'quota_gb': 0}).isLimited, isFalse);
  });

  const maxCount = 0x7fffffffffffffff;

  test(
    'invalid numeric member fields cannot throw or create negative usage',
    () {
      for (final value in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
        -1,
      ]) {
        final member = VpsMember.fromJson({
          'used_up': value,
          'used_down': value,
          'quota_gb': value,
        });
        expect(member.usedUp, 0);
        expect(member.usedDown, 0);
        expect(member.used, 0);
        expect(member.quotaGb, 0);
        expect(member.quotaBytes, 0);
      }
    },
  );

  test('two maximum byte counters do not overflow their sum', () {
    final member = VpsMember.fromJson({
      'used_up': maxCount,
      'used_down': maxCount,
      'quota_gb': 10,
    });
    expect(member.usedUp, maxCount);
    expect(member.used, maxCount.toDouble() * 2);
    expect(member.used.isFinite, isTrue);
    expect(member.quotaBytes, 10 * 1024 * 1024 * 1024);
  });

  test(
    'large finite counters saturate and an overflowing quota is unusable',
    () {
      final member = VpsMember.fromJson({
        'used_up': 1e100,
        'used_down': 1e100,
        'quota_gb': 1e308,
      });
      expect(member.usedUp, maxCount);
      expect(member.usedDown, maxCount);
      expect(member.used.isFinite, isTrue);
      expect(member.quotaBytes, 0);
    },
  );

  test('direct construction also guards displayed usage and quota bytes', () {
    for (final quota in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
      -1.0,
      1e308,
    ]) {
      final member = VpsMember(
        name: 'Member',
        enabled: true,
        usedUp: -1,
        usedDown: maxCount,
        quotaGb: quota,
      );
      expect(member.used, maxCount.toDouble());
      expect(member.quotaBytes, 0);
    }
  });
}
