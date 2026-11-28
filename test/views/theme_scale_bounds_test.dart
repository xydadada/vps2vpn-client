import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/manager/theme_manager.dart';
import 'package:fl_clash/models/config.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/views/theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart';

Future<ProviderContainer> _pumpTheme(
  WidgetTester tester, {
  required double savedScale,
  required Brightness brightness,
  bool enabled = true,
}) async {
  const size = Size(1400, 2800);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 1.4;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final config = Config.fromJson({
    'themeProps': {
      'textScale': {'enable': enabled, 'scale': savedScale},
    },
  });
  final container = ProviderContainer(
    overrides: [
      viewSizeProvider.overrideWithBuild((_, _) => size),
      themeSettingProvider.overrideWithBuild((_, _) => config.themeProps),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: PrismApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          AppUiLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(brightness: brightness),
        textScale: enabled ? config.themeProps.textScale.scale : null,
        minTextScale: minTextScale,
        maxTextScale: maxTextScale,
        builder: (_, child) => AppViewScope(child: child!),
        home: const ThemeView(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  expect(container.read(themeSettingProvider), same(config.themeProps));
  return container;
}

void _expectScale(WidgetTester tester, double expected, String label) {
  final slider = tester.widget<Slider>(find.byType(Slider));
  expect(slider.value, expected);
  expect(slider.label, label);
  expect(find.text(label), findsOneWidget);
  final page = tester.element(find.byType(ThemeView));
  final preview = tester.element(
    find.text(AppLocalizations.of(page).textScalePreview),
  );
  expect(MediaQuery.textScalerOf(page).scale(1), expected);
  expect(MediaQuery.textScalerOf(preview).scale(1), expected);
}

void main() {
  for (final brightness in Brightness.values) {
    for (final (name, saved, expected, label) in const [
      ('finite overflow', 1e308, 1.4, '140%'),
      ('negative', -1.0, 0.8, '80%'),
      ('NaN', double.nan, 1.4, '140%'),
      ('positive infinity', double.infinity, 1.4, '140%'),
      ('negative infinity', double.negativeInfinity, 0.8, '80%'),
      ('lower boundary', 0.8, 0.8, '80%'),
      ('upper boundary', 1.4, 1.4, '140%'),
      ('ordinary scale', 1.2, 1.2, '120%'),
    ]) {
      testWidgets('$name uses the app scale in ${brightness.name}', (
        tester,
      ) async {
        await _pumpTheme(tester, savedScale: saved, brightness: brightness);
        _expectScale(tester, expected, label);
        expect(
          Theme.of(tester.element(find.byType(ThemeView))).brightness,
          brightness,
        );
      });
    }
  }

  testWidgets('disabled custom scale follows the system without changing it', (
    tester,
  ) async {
    final container = await _pumpTheme(
      tester,
      savedScale: 1e308,
      brightness: Brightness.dark,
      enabled: false,
    );
    _expectScale(tester, 1.4, '140%');
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(container.read(themeSettingProvider).textScale.enable, isFalse);
    expect(container.read(themeSettingProvider).textScale.scale, 1e308);
  });
}
