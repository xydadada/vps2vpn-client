import 'package:fl_clash/vps2vpn/qr_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  testWidgets('a link too long for a QR code says so instead of failing', (
    tester,
  ) async {
    await tester.pumpWidget(
      TestApp(
        includeNavigatorKey: false,
        locale: const Locale('en'),
        child: VpsQrCode('https://sub.example.com/${'x' * 5000}'),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('too long for a QR code'), findsOneWidget);
  });

  testWidgets('an ordinary link draws a code', (tester) async {
    await tester.pumpWidget(
      const TestApp(
        includeNavigatorKey: false,
        locale: Locale('en'),
        child: VpsQrCode('https://sub.example.com/s/abc'),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('too long'), findsNothing);
  });
}
