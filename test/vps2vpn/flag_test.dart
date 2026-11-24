import 'package:fl_clash/ui/fonts.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  test('a two-letter code becomes its regional indicator pair', () {
    expect(vpsFlagEmoji('us'), '\u{1F1FA}\u{1F1F8}');
    expect(vpsFlagEmoji(' SG '), '\u{1F1F8}\u{1F1EC}');
    expect(vpsFlagEmoji(''), isNull);
    expect(vpsFlagEmoji('USA'), isNull);
    expect(vpsFlagEmoji('1A'), isNull);
    expect(vpsFlagEmoji('中国'), isNull);
  });

  testWidgets('a flag is drawn in the bundled emoji font', (tester) async {
    await tester.pumpWidget(
      const TestApp(includeNavigatorKey: false, child: VpsFlag('jp')),
    );
    final text = tester.widget<Text>(find.text('\u{1F1EF}\u{1F1F5}'));
    expect(text.style?.fontFamily, FontFamily.twEmoji.value);
    expect(find.bySemanticsLabel('JP'), findsOneWidget);
  });

  testWidgets('a code that is no country stays as letters', (tester) async {
    await tester.pumpWidget(
      const TestApp(includeNavigatorKey: false, child: VpsFlag('x1')),
    );
    expect(find.text('X1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
