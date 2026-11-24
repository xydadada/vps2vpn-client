import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

final _fade = find.descendant(
  of: find.byType(VpsBreathe),
  matching: find.byType(FadeTransition),
);

Widget _app({required bool still, required int round}) => TestApp(
  includeNavigatorKey: false,
  child: MediaQuery(
    data: MediaQueryData(disableAnimations: still),
    child: VpsBreathe(
      active: true,
      child: SizedBox(key: ValueKey(round), width: 10, height: 10),
    ),
  ),
);

void main() {
  testWidgets('rebuilding keeps one fade, not a new one each time (C11-03)', (
    tester,
  ) async {
    await tester.pumpWidget(_app(still: false, round: 0));
    final first = tester.widget<FadeTransition>(_fade);
    for (var round = 1; round < 4; round++) {
      await tester.pumpWidget(_app(still: false, round: round));
      final again = tester.widget<FadeTransition>(_fade);
      expect(identical(again.opacity, first.opacity), isTrue);
    }
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion keeps it still', (tester) async {
    await tester.pumpWidget(_app(still: true, round: 0));
    expect(_fade, findsNothing);
  });
}
