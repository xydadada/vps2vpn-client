import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
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

  test('a top-up or renewal the subscription has not caught up with', () {
    final expire = DateTime(2026, 12, 31);
    final member = VpsMember(
      name: 'Ann',
      enabled: true,
      quotaGb: 100,
      expireAt: expire,
    );
    final same = SubscriptionInfo(
      total: 100 * (1 << 30),
      expire: expire.millisecondsSinceEpoch ~/ 1000,
    );
    expect(vpsHeaderBehindPanel(same, member), isFalse);
    expect(
      vpsHeaderBehindPanel(same.copyWith(total: 50 * (1 << 30)), member),
      isTrue,
    );
    expect(
      vpsHeaderBehindPanel(
        same.copyWith(expire: same.expire - 30 * 86400),
        member,
      ),
      isTrue,
    );
    const unlimited = VpsMember(name: 'Bo', enabled: true);
    expect(vpsHeaderBehindPanel(const SubscriptionInfo(), unlimited), isFalse);
  });

  group('config_version', () {
    test('the panel field is read only when it looks like one', () {
      expect(
        VpsMember.fromJson({
          'config_version': '0A1b2c3d4e5f6789',
        }).configVersion,
        '0a1b2c3d4e5f6789',
      );
      for (final bad in [null, '', 'not hex', 12, 'f' * 65]) {
        expect(
          VpsMember.fromJson({'config_version': bad}).configVersion,
          isNull,
        );
      }
    });

    test('a new version fetches once and is kept after the fetch', () async {
      String? stored = '1111111111111111';
      var fetched = 0;
      Future<bool> follow(String v) => vpsFollowConfigVersion(
        version: v,
        load: () async => stored,
        save: (value) async => stored = value,
        update: () async => fetched++,
      );
      expect(await follow('1111111111111111'), isFalse);
      expect(fetched, 0);
      expect(await follow('2222222222222222'), isTrue);
      expect(fetched, 1);
      expect(stored, '2222222222222222');
      expect(await follow('2222222222222222'), isFalse);
      expect(fetched, 1);
    });

    test(
      'a failed fetch keeps the old version, so it is tried again',
      () async {
        String? stored = '1111111111111111';
        await expectLater(
          vpsFollowConfigVersion(
            version: '2222222222222222',
            load: () async => stored,
            save: (value) async => stored = value,
            update: () async => throw const SocketException('down'),
          ),
          throwsA(isA<SocketException>()),
        );
        expect(stored, '1111111111111111');
      },
    );
  });
}
