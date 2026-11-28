import 'dart:ui' show PointerDeviceKind;

import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/site_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_app.dart';

Future<void> _pumpCard(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  await preferences.rebind();
  await tester.pumpWidget(
    TestApp(
      includeNavigatorKey: false,
      locale: const Locale('en'),
      overrides: [
        isStartProvider.overrideWithValue(false),
        currentGroupsStateProvider.overrideWithValue(
          const GroupsState(value: []),
        ),
      ],
      child: const Center(
        child: SizedBox(width: 600, child: VpsSiteTestCard()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _row(String name) =>
    find.ancestor(of: find.text(name), matching: find.byType(Row)).first;

bool _focused(WidgetTester tester, String name) => tester
    .widget<FocusableActionDetector>(
      find.descendant(
        of: _row(name),
        matching: find.byType(FocusableActionDetector),
      ),
    )
    .focusNode!
    .hasPrimaryFocus;

double _opacity(WidgetTester tester, String name) => tester
    .widget<AnimatedOpacity>(
      find.descendant(of: _row(name), matching: find.byType(AnimatedOpacity)),
    )
    .opacity;

void main() {
  test('a bare host becomes an https site named after the host', () {
    expect(vpsSiteFrom(' www.github.com '), (
      name: 'github.com',
      url: 'https://www.github.com',
    ));
    expect(
      vpsSiteFrom('http://example.com/path')?.url,
      'http://example.com/path',
    );
  });

  test('what is not a web address is refused', () {
    for (final bad in ['', 'hello', 'ftp://example.com', 'two words.com']) {
      expect(vpsSiteFrom(bad), isNull, reason: bad);
    }
  });

  testWidgets('Tab reveals the remove button and Enter removes that site', (
    tester,
  ) async {
    await _pumpCard(tester);
    expect(_opacity(tester, 'Apple'), 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(_focused(tester, 'Apple'), isTrue);
    expect(_opacity(tester, 'Apple'), 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Apple'), findsNothing);
    expect(find.text('GitHub'), findsOneWidget);
    expect(await preferences.getVpsSites(), [
      for (final site in vpsDefaultSites.skip(1)) '${site.name}|${site.url}',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('focus follows Tab and Space removes only the focused site', (
    tester,
  ) async {
    await _pumpCard(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(_focused(tester, 'GitHub'), isTrue);
    expect(_opacity(tester, 'Apple'), 0);
    expect(_opacity(tester, 'GitHub'), 1);
    final remove = tester.widget<VpsPressable>(
      find.descendant(of: _row('GitHub'), matching: find.byType(VpsPressable)),
    );
    expect(remove.semanticLabel, 'Remove GitHub');

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('GitHub'), findsNothing);
    expect(find.text('Apple'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pointer hover still reveals and hides the remove button', (
    tester,
  ) async {
    await _pumpCard(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(_row('Apple')));
    await tester.pumpAndSettle();
    expect(_opacity(tester, 'Apple'), 1);
    await mouse.moveTo(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(_opacity(tester, 'Apple'), 0);
    expect(tester.takeException(), isNull);
  });
}
