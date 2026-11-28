import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  for (final tinted in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('long chip fits a narrow card: tinted=$tinted scale=$scale', (
        tester,
      ) async {
        const label = 'Connected · finding out why · 正在检查当前线路';
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          TestApp(
            includeNavigatorKey: false,
            child: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Center(
                child: SizedBox(
                  width: 160,
                  child: Wrap(
                    children: [
                      VpsChip(label: label, unit: 'ms', tinted: tinted),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byType(VpsChip)).width,
          lessThanOrEqualTo(160),
        );
        expect(
          find.bySemanticsLabel(RegExp(RegExp.escape(label))),
          findsOneWidget,
        );
        semantics.dispose();
      });
    }
  }
}
