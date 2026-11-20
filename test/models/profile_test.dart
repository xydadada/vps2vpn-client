import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

void main() {
  group('SubscriptionInfo', () {
    test('parses subscription-userinfo header values', () {
      final info = SubscriptionInfo.formHString(
        'upload=10; download=20; total=100; expire=200',
      );

      expect(info.upload, 10);
      expect(info.download, 20);
      expect(info.total, 100);
      expect(info.expire, 200);
    });

    test('keeps invalid expiry distinct from absent expiry', () {
      expect(SubscriptionInfo.formHString(null), const SubscriptionInfo());

      final info = SubscriptionInfo.formHString(
        'upload=bad; download=20; total=; expire=abc',
      );

      expect(info.upload, 0);
      expect(info.download, 20);
      expect(info.total, 0);
      expect(info.expire, -1);
      expect(info.expireDate, isNull);
      expect(SubscriptionInfo.formHString('expire=0.5').expire, -1);
      expect(SubscriptionInfo.formHString('expire=0').expire, 0);
    });

    test('skips empty and malformed fields instead of throwing', () {
      final info = SubscriptionInfo.formHString(
        'upload=10;; download; =5; total=100;',
      );

      expect(info.upload, 10);
      expect(info.download, 0);
      expect(info.total, 100);
    });

    test('truncates decimal and exponent counts', () {
      final info = SubscriptionInfo.formHString(
        'Upload=1.5; download=2.4e3; total=1.073741824E10; expire=Infinity',
      );

      expect(info.upload, 1);
      expect(info.download, 2400);
      expect(info.total, 10737418240);
      expect(info.expire, -1);
    });

    test('invalid persisted expiry does not throw or become an epoch date', () {
      for (final expire in [-1, 8640000000001, maxCounterValue]) {
        final info = SubscriptionInfo.fromJson({'expire': expire});
        expect(info.expire, -1);
        expect(info.expireDate, isNull);
      }
      expect(const SubscriptionInfo(expire: 0).expireDate, isNull);
      expect(
        const SubscriptionInfo(
          expire: 1893456000,
        ).expireDate!.millisecondsSinceEpoch,
        1893456000000,
      );
    });

    test('negative and oversized header counters cannot wrap usage', () {
      final info = SubscriptionInfo.formHString(
        'upload=1e300; download=9223372036854775807; '
        'total=100; expire=8640000000001',
      );
      expect(info.used, maxCounterValue);
      expect(info.usage, 1.0);
      expect(info.remaining, 0);
      expect(info.expireDate, isNull);
      final negative = SubscriptionInfo.formHString(
        'upload=-10; download=20; total=100; expire=-1',
      );
      expect(negative.upload, 0);
      expect(negative.used, 20);
      expect(negative.remaining, 80);
      expect(negative.usage, 0.2);
      expect(negative.expire, -1);
    });
  });

  group('Profile factories', () {
    test('normal takes its type from whether it has a url', () {
      expect(Profile.normal().type, ProfileType.file);
      expect(
        Profile.normal(url: 'https://example.com/profile.yaml').type,
        ProfileType.url,
      );
    });

    test('custom never updates itself', () {
      final profile = Profile.custom(label: 'Mine');

      expect(profile.type, ProfileType.custom);
      expect(profile.url, isEmpty);
      expect(profile.realAutoUpdate, false);
    });
  });

  group('ProfileExtension', () {
    test('derives auto update, label, filename, and updating key', () {
      const fileProfile = Profile(
        id: 7,
        autoUpdateDuration: defaultUpdateDuration,
      );
      const urlProfile = Profile(
        id: 8,
        type: ProfileType.url,
        label: 'Remote',
        url: 'https://example.com/profile.yaml',
        autoUpdate: true,
        autoUpdateDuration: defaultUpdateDuration,
      );

      expect(fileProfile.type, ProfileType.file);
      expect(fileProfile.realAutoUpdate, false);
      expect(fileProfile.realLabel, '7');
      expect(fileProfile.fileName, '7.yaml');
      expect(fileProfile.updatingKey, 'profile_7');

      expect(urlProfile.type, ProfileType.url);
      expect(urlProfile.realAutoUpdate, true);
      expect(urlProfile.realLabel, 'Remote');
      expect(urlProfile.copyWith(label: '').realLabel, 'example.com');

      expect(fileProfile.exportFileName, '7.yaml');
      expect(urlProfile.exportFileName, 'Remote.yaml');
      expect(urlProfile.copyWith(label: 'a.YML').exportFileName, 'a.YML');
    });

    test('an unnamed profile falls back to its url host, then its id', () {
      final profiles = [
        const Profile(
          id: 1,
          label: 'example.com',
          autoUpdateDuration: defaultUpdateDuration,
        ),
      ];
      const remote = Profile(
        id: 2,
        type: ProfileType.url,
        url: 'https://example.com:8443/api/subscribe?token=1',
        autoUpdateDuration: defaultUpdateDuration,
      );
      const local = Profile(id: 3, autoUpdateDuration: defaultUpdateDuration);

      expect(remote.defaultLabel, 'example.com');
      expect(local.defaultLabel, '3');
      expect(profiles.optimizeLabel(remote).label, 'example.com(1)');
      expect(profiles.optimizeLabel(local).label, '3');
    });
  });

  group('ProfilesExt', () {
    test('gets profile by id', () {
      const profiles = [
        Profile(id: 1, label: 'A', autoUpdateDuration: defaultUpdateDuration),
        Profile(id: 2, label: 'B', autoUpdateDuration: defaultUpdateDuration),
      ];

      expect(profiles.getProfile(2)?.label, 'B');
      expect(profiles.getProfile(3), isNull);
      expect(profiles.getProfile(null), isNull);
    });

    test('optimizes duplicate labels with incremented suffix', () {
      const profiles = [
        Profile(
          id: 1,
          label: 'Work',
          autoUpdateDuration: defaultUpdateDuration,
        ),
        Profile(
          id: 2,
          label: 'Work(1)',
          autoUpdateDuration: defaultUpdateDuration,
        ),
      ];
      const newProfile = Profile(
        id: 3,
        label: 'Work',
        autoUpdateDuration: defaultUpdateDuration,
      );

      expect(profiles.optimizeLabel(newProfile).label, 'Work(2)');
    });
  });
}
