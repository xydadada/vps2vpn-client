import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' show ColorScheme, Theme, ThemeData;

import '../helpers/test_app.dart';

double _contrast(Color a, Color b) {
  final x = a.computeLuminance() + 0.05;
  final y = b.computeLuminance() + 0.05;
  return x > y ? x / y : y / x;
}

Future<VpsPalette> _paletteUnder(
  WidgetTester tester, {
  Color? seed,
  required Brightness brightness,
}) async {
  late VpsPalette palette;
  Widget probe = Builder(
    builder: (context) {
      palette = VpsPalette.of(context);
      return const SizedBox();
    },
  );
  if (seed != null) {
    probe = VpsAccentScope(light: seed, dark: seed, child: probe);
  }
  await tester.pumpWidget(
    TestApp(
      includeNavigatorKey: false,
      child: Theme(
        data: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF808080),
            brightness: brightness,
          ),
        ),
        child: probe,
      ),
    ),
  );
  return palette;
}

void main() {
  const seeds = [
    Color(0xFF0A84FF),
    Color(0xFF5E5CE6),
    Color(0xFFAF52DE),
    Color(0xFFFF375F),
    Color(0xFF0FB5AE),
    Color(0xFFFFCC00),
  ];

  testWidgets('coral, and no theme colour at all, keep the drawn palette', (
    tester,
  ) async {
    final plain = await _paletteUnder(tester, brightness: Brightness.dark);
    final coral = await _paletteUnder(
      tester,
      seed: vpsCoral,
      brightness: Brightness.dark,
    );
    expect(plain.accent, const Color(0xFFFF7A5C));
    expect(coral.accent, plain.accent);
  });

  testWidgets('any theme colour gives an accent white text reads on', (
    tester,
  ) async {
    for (final seed in seeds) {
      final light = await _paletteUnder(
        tester,
        seed: seed,
        brightness: Brightness.light,
      );
      final dark = await _paletteUnder(
        tester,
        seed: seed,
        brightness: Brightness.dark,
      );
      expect(light.seed, seed);
      expect(
        _contrast(light.accent, light.accentInk),
        greaterThan(3),
        reason: '$seed',
      );
      expect(
        _contrast(dark.accent, dark.accentInk),
        greaterThan(2.5),
        reason: '$seed',
      );
      expect(_contrast(dark.accent, dark.bg), greaterThan(4), reason: '$seed');
      expect(dark.gradient, hasLength(3));
    }
  });

  test('the lightness search lands inside the asked luminance', () {
    for (final seed in seeds) {
      final lum = vpsAtLuminance(
        HSLColor.fromColor(seed),
        0.2,
        0.35,
      ).toColor().computeLuminance();
      expect(lum, inInclusiveRange(0.19, 0.36), reason: '$seed');
    }
  });
}
