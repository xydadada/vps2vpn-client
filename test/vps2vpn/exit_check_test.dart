import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/vps2vpn/exit_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a clock fits the countries it can belong to', () {
    expect(vpsTimeZoneFits('JP', const Duration(hours: 9)), isTrue);
    expect(vpsTimeZoneFits('jp', const Duration(hours: 8)), isFalse);
    expect(vpsTimeZoneFits('US', const Duration(hours: -5)), isTrue);
    expect(vpsTimeZoneFits('US', const Duration(hours: 8)), isFalse);
    expect(
      vpsTimeZoneFits('IN', const Duration(hours: 5, minutes: 30)),
      isTrue,
    );
    expect(vpsTimeZoneFits('ZZ', Duration.zero), isNull);
  });

  test('the system language is checked against the exit country', () {
    expect(vpsLanguageFits('US', 'en_US'), isTrue);
    expect(vpsLanguageFits('US', 'zh-Hans-CN'), isFalse);
    expect(vpsLanguageFits('SG', 'zh_CN'), isTrue);
    expect(vpsLanguageFits('ZZ', 'en'), isNull);
  });

  test('copied addresses hide their last part', () {
    expect(vpsMaskLast('203.0.113.7'), '203.0.113.*');
    expect(vpsMaskLast('2001:db8::1'), '2001:db8::*');
    expect(vpsMaskLast('nonsense'), '*');
  });

  test('an IPv6 answer counts only when it is an IPv6 address', () {
    expect(
      parseIpv6Answer(
        const OutboundIpResult(
          url: 'https://v6.ident.me/json',
          body: '{"ip":"2001:db8::1","cc":"JP"}',
        ),
      )?.countryCode,
      'JP',
    );
    for (final ip in ['203.0.113.7', 'not:an:address']) {
      expect(
        parseIpv6Answer(
          OutboundIpResult(
            url: 'https://v6.ident.me/json',
            body: '{"ip":"$ip","cc":"JP"}',
          ),
        ),
        isNull,
      );
    }
    expect(
      parseIpv6Answer(
        const OutboundIpResult(
          url: 'https://v6.ident.me/json',
          error: 'timeout',
        ),
      ),
      isNull,
    );
  });

  test('the DNS answer names the resolver and where it is', () {
    final dns = parseEdnsAnswer(
      '{"dns":{"geo":"Japan - Example","ip":"198.51.100.53"}}',
    );
    expect(dns?.geo, 'Japan - Example');
    expect(parseEdnsAnswer('<html>'), isNull);
  });
}
