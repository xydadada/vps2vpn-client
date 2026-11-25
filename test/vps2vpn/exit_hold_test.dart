import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/vps2vpn/exit_hold.dart';
import 'package:flutter_test/flutter_test.dart';

const _au = IpInfo(ip: '203.0.113.10', countryCode: 'AU');
const _jp = IpInfo(ip: '198.51.100.20', countryCode: 'JP');

void main() {
  late int expired;
  late VpsExitHold hold;

  setUp(() {
    expired = 0;
    hold = VpsExitHold(onExpire: () => expired++);
  });

  tearDown(() => hold.dispose());

  testWidgets('a new country shows as soon as its probe answers', (
    tester,
  ) async {
    expect(hold.steady(_au, on: true), _au);
    expect(hold.steady(null, on: true), _au);
    await tester.pump(const Duration(seconds: 1));
    expect(hold.steady(_jp, on: true), _jp);
    await tester.pump(const Duration(seconds: 5));
    expect(expired, 0);
    expect(hold.steady(_jp, on: true), _jp);
  });

  testWidgets('a failed probe falls back to the line after three seconds', (
    tester,
  ) async {
    hold.steady(_au, on: true);
    expect(hold.steady(null, on: true), _au);
    await tester.pump(const Duration(milliseconds: 2900));
    expect(expired, 0);
    expect(hold.steady(null, on: true), _au);
    await tester.pump(const Duration(milliseconds: 200));
    expect(expired, 1);
    expect(hold.steady(null, on: true), isNull);
    await tester.pump(const Duration(seconds: 5));
    expect(expired, 1);
  });

  testWidgets('nothing is held before the first answer or once off', (
    tester,
  ) async {
    expect(hold.steady(null, on: true), isNull);
    hold.steady(_au, on: true);
    expect(hold.steady(null, on: false), isNull);
    expect(hold.steady(null, on: true), isNull);
    await tester.pump(const Duration(seconds: 5));
    expect(expired, 0);
  });
}
