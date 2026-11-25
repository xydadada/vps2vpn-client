import 'dart:math' as math;

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

double _lightness(Color c) {
  final y = c.computeLuminance();
  return y > 0.008856 ? 116 * math.pow(y, 1 / 3) - 16 : 903.3 * y;
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

  testWidgets('grey and status text read at AA on a card, hue kept', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      for (final seed in [null, ...seeds]) {
        final p = await _paletteUnder(
          tester,
          seed: seed,
          brightness: brightness,
        );
        for (final role in [p.soft, p.muted, p.accent, p.good, p.warn, p.bad]) {
          final body = p.ink(role);
          final large = p.ink(role, large: true);
          final why = '$brightness $seed $role';
          expect(
            _contrast(body, p.card),
            greaterThanOrEqualTo(4.5),
            reason: why,
          );
          expect(
            _contrast(large, p.card),
            greaterThanOrEqualTo(3),
            reason: why,
          );
          if (role != p.soft && _contrast(role, p.card) >= 4.5) {
            expect(body, role, reason: why);
          }
          final hue = HSLColor.fromColor(role);
          if (hue.saturation > 0.2) {
            expect(
              HSLColor.fromColor(body).hue,
              closeTo(hue.hue, 3),
              reason: why,
            );
          }
        }
        for (final large in [false, true]) {
          final gap =
              _lightness(p.ink(p.soft, large: large)) -
              _lightness(p.ink(p.muted, large: large));
          expect(gap.abs(), greaterThanOrEqualTo(8), reason: '$brightness');
        }
        expect(p.ink(p.text), p.text);
        expect(p.ink(p.line), p.line);
      }
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
