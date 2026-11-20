import 'package:fl_clash/common/datetime.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

const _legacyBypass = [
  '*zhihu.com',
  '*zhimg.com',
  '*jd.com',
  '100ime-iat-api.xfyun.cn',
  '*360buyimg.com',
  'localhost',
  '*.local',
  '127.*',
  '10.*',
  '172.16.*',
  '172.17.*',
  '172.18.*',
  '172.19.*',
  '172.2*',
  '172.30.*',
  '172.31.*',
  '192.168.*',
];

bool _bypasses(String host) => defaultBypassDomain.any(
  (pattern) => RegExp(
    '^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$',
  ).hasMatch(host),
);

void main() {
  test('default IPv4 bypass covers only the private 172.16/12 range', () {
    for (var second = 0; second < 256; second++) {
      for (final tail in ['0.1', '255.254']) {
        final address = '172.$second.$tail';
        expect(
          _bypasses(address),
          second >= 16 && second <= 31,
          reason: address,
        );
      }
    }
    expect(_bypasses('10.20.30.40'), isTrue);
    expect(_bypasses('192.168.1.2'), isTrue);
    expect(_bypasses('127.0.0.1'), isTrue);
    expect(_bypasses('localhost'), isTrue);
  });

  test('exact saved defaults migrate without changing custom bypass policy', () {
    expect(
      NetworkProps.fromJson({'bypassDomain': _legacyBypass}).bypassDomain,
      defaultBypassDomain,
    );
    expect(
      NetworkProps.fromJson({
        'bypassDomain': [..._legacyBypass, windowsLocalBypass],
      }).bypassDomain,
      [...defaultBypassDomain, windowsLocalBypass],
    );
    const custom = ['172.2*', 'internal.example'];
    expect(
      NetworkProps.fromJson({'bypassDomain': custom}).bypassDomain,
      custom,
    );
    final reordered = _legacyBypass.reversed.toList();
    expect(
      NetworkProps.fromJson({'bypassDomain': reordered}).bypassDomain,
      reordered,
    );
  });

  test('timestamp normalization rejects invalid values before arithmetic', () {
    for (final value in <Object?>[
      null,
      true,
      [],
      {},
      '',
      'invalid',
      'Infinity',
      'NaN',
      '1e100',
      '9223372036854775807',
      -1,
      0,
      double.nan,
      double.infinity,
      double.negativeInfinity,
      9223372036854775807,
      maxDisplayUnixSeconds + 1,
    ]) {
      expect(unixSecondsOrZero(value), 0, reason: '$value');
      expect(dateTimeFromUnixSeconds(value), isNull, reason: '$value');
    }
  });

  test('valid timestamps keep seconds and the final four-digit UTC year', () {
    expect(unixSecondsOrZero(1), 1);
    expect(unixSecondsOrZero('1700000000'), 1700000000);
    expect(unixSecondsOrZero(1700000000.75), 1700000000);
    expect(
      DateTime.utc(9999, 12, 31, 23, 59, 59).millisecondsSinceEpoch ~/ 1000,
      maxDisplayUnixSeconds,
    );
    expect(unixSecondsOrZero(maxDisplayUnixSeconds), maxDisplayUnixSeconds);
    expect(
      dateTimeFromUnixSeconds(1700000000)?.millisecondsSinceEpoch,
      1700000000000,
    );
    final lastLocal = DateTime.fromMillisecondsSinceEpoch(
      maxDisplayUnixSeconds * 1000,
    );
    expect(
      dateTimeFromUnixSeconds(maxDisplayUnixSeconds),
      lastLocal.year > 9999 ? isNull : equals(lastLocal),
    );
  });

  test('subscription header dates cannot crash the view with extreme values', () {
    for (final raw in [
      '-1',
      'NaN',
      'Infinity',
      '1e100',
      '9223372036854775807',
      '${maxDisplayUnixSeconds + 1}',
    ]) {
      final info = SubscriptionInfo.formHString('upload=3; expire=$raw');
      expect(info.upload, 3);
      expect(info.expire, 0, reason: raw);
      expect(info.expireDate, isNull, reason: raw);
    }
    expect(
      SubscriptionInfo.formHString(
        'expire=$maxDisplayUnixSeconds',
      ).expire,
      maxDisplayUnixSeconds,
    );
  });

  test('restored subscription JSON validates dates independently of headers', () {
    for (final value in <Object?>[
      -1,
      double.nan,
      double.infinity,
      '1e100',
      9223372036854775807,
      maxDisplayUnixSeconds + 1,
    ]) {
      final info = SubscriptionInfo.fromJson({'expire': value, 'total': 42});
      expect(info.total, 42);
      expect(info.expire, 0, reason: '$value');
      expect(info.expireDate, isNull, reason: '$value');
    }
    expect(
      SubscriptionInfo.fromJson({'expire': maxDisplayUnixSeconds}).expire,
      maxDisplayUnixSeconds,
    );
  });

  test('large subscription counters do not overflow before division', () {
    const maximum = 9223372036854775807;
    const info = SubscriptionInfo(
      upload: maximum,
      download: maximum,
      total: maximum,
    );
    expect(info.usage, 1.0);
    expect(
      SubscriptionInfo.fromJson({
        'upload': maximum,
        'download': maximum,
        'total': maximum,
      }).usage,
      1.0,
    );
  });

  test('directly constructed and core subscription dates are safe too', () {
    const malformed = SubscriptionInfo(expire: 9223372036854775807);
    expect(malformed.expireDate, isNull);
    for (final value in <Object?>[
      -1,
      double.infinity,
      double.nan,
      9223372036854775807,
      maxDisplayUnixSeconds + 1,
    ]) {
      final info = subscriptionInfoFormCore({'Upload': 4, 'Expire': value})!;
      expect(info.upload, 4);
      expect(info.expire, 0, reason: '$value');
      expect(info.expireDate, isNull, reason: '$value');
    }
    expect(
      subscriptionInfoFormCore({'Expire': maxDisplayUnixSeconds})?.expire,
      maxDisplayUnixSeconds,
    );
  });
}
