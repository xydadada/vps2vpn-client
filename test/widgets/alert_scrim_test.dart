import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

Iterable<Color> _scrims(WidgetTester tester) => tester
    .widgetList<ColoredBox>(
      find.descendant(
        of: find.byType(AlertScrim),
        matching: find.byType(ColoredBox),
      ),
    )
    .map((box) => box.color);

void main() {
  testWidgets('chrome outside the navigator dims with an alert, and clears', (
    tester,
  ) async {
    late BuildContext page;
    await tester.pumpWidget(
      TestApp(
        child: Column(
          children: [
            const SizedBox(height: 32, child: AlertScrim()),
            Expanded(
              child: Builder(
                builder: (context) {
                  page = context;
                  return const SizedBox.expand();
                },
              ),
            ),
          ],
        ),
      ),
    );
    expect(_scrims(tester), isEmpty);

    unawaited(
      dialogs.showCommonDialog<void>(context: page, child: const Text('Alert')),
    );
    await tester.pumpAndSettle();
    final scrim = page.colorScheme.alertScrim;
    expect(_scrims(tester).single.a, closeTo(scrim.a, 0.01));
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .descendant(
                  of: find.byType(AlertScrim),
                  matching: find.byType(IgnorePointer),
                )
                .first,
          )
          .ignoring,
      isTrue,
    );

    Navigator.of(page).pop();
    await tester.pumpAndSettle();
    expect(_scrims(tester), isEmpty);
  });
}
