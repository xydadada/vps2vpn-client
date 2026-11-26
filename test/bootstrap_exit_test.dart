import 'dart:io';

import 'package:fl_clash/bootstrap.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/disclaimer.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import 'helpers/app_paths.dart';
import 'helpers/fake_desktop_window.dart';
import 'helpers/preferences.dart';
import 'helpers/test_app.dart';

class _UnavailableStore extends InMemorySharedPreferencesStore {
  _UnavailableStore() : super.empty();

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async => throw StateError('Preferences unavailable');
}

class _ExitingSystem extends SystemAction {
  final saves = <bool>[];

  @override
  Future<void> updateTray() async {}

  @override
  Future<void> handleExit([bool needSave = true]) async {
    saves.add(needSave);
  }
}

class _NeverStartCore extends CoreAction {
  var starts = 0;

  @override
  Future<void> startCore() async {
    starts++;
    throw StateError('Core must not start after startup was cancelled');
  }
}

void main() {
  late Directory directory;
  late ProviderContainer container;
  late _ExitingSystem systemAction;
  late _NeverStartCore coreAction;

  setUpAll(() => loadAppLocalizations(const Locale('en')));

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bootstrap_exit');
    await useAppPaths(directory);
    await mockPreferences();
    FakeDesktopWindow().install();
    systemAction = _ExitingSystem();
    coreAction = _NeverStartCore();
    container = ProviderContainer(
      overrides: [
        systemActionProvider.overrideWith(() => systemAction),
        coreActionProvider.overrideWith(() => coreAction),
      ],
    );
    globalState.container = container;
    globalState.isAttach = false;
    globalState.packageInfo = PackageInfo(
      appName: 'vps2vpn',
      packageName: 'test.vps2vpn',
      version: '1.0.33',
      buildNumber: '1',
    );
  });

  tearDown(() async {
    globalState.isAttach = false;
    container.dispose();
    await mockPreferences();
    await directory.delete(recursive: true);
  });

  Future<void> host(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(child: SizedBox.shrink()),
      ),
    );
    await tester.pump();
  }

  testWidgets('corrupt preferences stop startup after the exit returns', (
    tester,
  ) async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = _UnavailableStore();
    await preferences.rebind();
    await host(tester);

    final attached = bootstrap.attach();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await attached, isFalse);
    expect(systemAction.saves, [false]);
    expect(coreAction.starts, 0);
    expect(globalState.isAttach, isFalse);
    expect(container.read(initProvider), isFalse);
    expect(find.byType(DisclaimerView), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('declining the disclaimer leaves startup unattached', (
    tester,
  ) async {
    await host(tester);

    final attached = bootstrap.attach();
    await tester.pumpAndSettle();
    expect(find.byType(DisclaimerView), findsOneWidget);
    await tester.tap(find.text('Exit'));
    await tester.pumpAndSettle();

    expect(await attached, isFalse);
    expect(systemAction.saves, [true]);
    expect(coreAction.starts, 0);
    expect(globalState.isAttach, isFalse);
    expect(container.read(initProvider), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
