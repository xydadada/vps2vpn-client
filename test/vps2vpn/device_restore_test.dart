import 'dart:async';

import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/devices.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

const _member = VpsMemberResult(
  member: VpsMember(name: 'Fixture', enabled: true, devices: true),
);
const _profile = Profile(
  id: 1,
  label: 'Fixture',
  url: 'https://panel.example.com/s/FixtureToken0123456789',
  autoUpdateDuration: Duration(hours: 1),
);

class _Removed extends VpsRemoved {
  @override
  Set<int> build() => {1, 2};
}

class _Setup extends SetupAction {
  final requests = <bool>[];

  @override
  void build() {}

  @override
  Future<bool> setRunning(bool running, {bool initialize = false}) async {
    requests.add(running);
    return true;
  }
}

class _Panel {
  final bases = <Uri>[];
  final bodies = <Map<String, Object?>?>[];
  final reply = Completer<(int, String, String?)>();

  Future<(int, String, String?)> call(
    String path, {
    Map<String, Object?>? body,
    Map<String, String> headers = const {},
  }) {
    expect(path, 'device');
    bodies.add(body);
    return reply.future;
  }
}

Future<({ProviderContainer container, _Setup setup, ValueNotifier<bool> shown})>
_pumpNotice(
  WidgetTester tester,
  _Panel panel, {
  Profile profile = _profile,
  Future<VpsMemberResult?> Function(Ref)? member,
}) async {
  tester.view.physicalSize = const Size(1100, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final setup = _Setup();
  final shown = ValueNotifier(true);
  addTearDown(shown.dispose);
  final container = ProviderContainer(
    overrides: [
      profilesProvider.overrideWith(
        () => TestProfiles([profile, _profile.copyWith(id: 2)]),
      ),
      currentProfileIdProvider.overrideWithBuild((_, _) => 1),
      vpsRemovedProvider.overrideWith(_Removed.new),
      vpsMemberProvider.overrideWith(member ?? (_) async => _member),
      vpsDeviceCallsProvider.overrideWithValue((base) {
        panel.bases.add(base);
        return panel.call;
      }),
      isStartProvider.overrideWithValue(false),
      setupActionProvider.overrideWith(() => setup),
    ],
  );
  addTearDown(container.dispose);
  globalState.container = container;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TestApp(
        includeNavigatorKey: false,
        locale: const Locale('en'),
        child: Center(
          child: SizedBox(
            width: 850,
            child: ValueListenableBuilder<bool>(
              valueListenable: shown,
              builder: (_, visible, _) =>
                  visible ? const VpsDeviceRemovedNotice() : const SizedBox(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container: container, setup: setup, shown: shown);
}

Future<void> _check(WidgetTester tester, _Panel panel) async {
  await tester.tap(find.text('Check again'));
  await tester.pumpAndSettle();
  expect(panel.bodies, hasLength(1));
  expect(panel.bodies.single?['device_id'], isNotEmpty);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final oldLoad = vpsDeviceLoad;
  final oldSave = vpsDeviceSave;
  final oldRemovedSave = vpsRemovedSave;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await preferences.rebind();
    vpsDeviceLoad = (_) async => '12345678-1234-4123-8123-123456789012';
    vpsDeviceSave = (_, _) async {};
    vpsRemovedSave = (_) async {};
    vpsRemovedDismissed.value = null;
    globalState.packageInfo = PackageInfo(
      appName: 'Fixture',
      packageName: 'example.fixture',
      version: '1.0.34',
      buildNumber: '1',
    );
  });
  tearDown(() {
    vpsDeviceLoad = oldLoad;
    vpsDeviceSave = oldSave;
    vpsRemovedSave = oldRemovedSave;
    vpsRemovedDismissed.value = null;
  });

  testWidgets('one explicit recheck clears removal without starting', (
    tester,
  ) async {
    final panel = _Panel();
    final page = await _pumpNotice(tester, panel);
    final keys = tester.allWidgets.map((widget) => widget.key).join('\n');
    expect(keys, isNot(contains(_profile.url)));
    expect(keys, isNot(contains('FixtureToken0123456789')));
    expect(panel.bodies, isEmpty);
    await _check(tester, panel);
    final checking = tester.widget<VpsButton>(
      find.widgetWithText(VpsButton, 'Checking…'),
    );
    expect(checking.onTap, isNull);
    await tester.tap(find.text('Checking…'));
    await tester.pump();
    expect(panel.bodies, hasLength(1));

    panel.reply.complete((200, '{"ok":true,"revoked":false}', null));
    await tester.pumpAndSettle();
    expect(page.container.read(vpsRemovedProvider), {2});
    expect(find.text('Check again'), findsNothing);
    expect(page.container.read(isStartProvider), isFalse);
    expect(page.setup.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final response in [
    (200, '{"ok":true,"revoked":true}', 'This device is still removed.'),
    (200, '{}', 'The server is out of reach; try again later'),
    (200, '{"revoked":false}', 'The server is out of reach; try again later'),
    (429, '{}', 'Too many tries; wait a while and try again'),
  ]) {
    testWidgets('unconfirmed ${response.$1} ${response.$2} keeps removal', (
      tester,
    ) async {
      final panel = _Panel();
      final page = await _pumpNotice(tester, panel);
      await _check(tester, panel);
      panel.reply.complete((response.$1, response.$2, null));
      await tester.pumpAndSettle();
      expect(page.container.read(vpsRemovedProvider), {1, 2});
      expect(find.textContaining(response.$3), findsOneWidget);
      expect(find.text('Check again'), findsOneWidget);
      expect(page.setup.requests, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a confirmed feature-off clears an existing removal', (
    tester,
  ) async {
    final panel = _Panel();
    final page = await _pumpNotice(
      tester,
      panel,
      member: (_) async => const VpsMemberResult(
        member: VpsMember(name: 'Fixture', enabled: true),
      ),
    );
    await _check(tester, panel);
    panel.reply.complete((503, '{"code":"feature_off"}', null));
    await tester.pumpAndSettle();
    expect(page.container.read(vpsRemovedProvider), {2});
    expect(page.setup.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final change in ['profile', 'url', 'dispose']) {
    testWidgets('a late response after $change cannot clear removal', (
      tester,
    ) async {
      final panel = _Panel();
      final page = await _pumpNotice(tester, panel);
      await _check(tester, panel);
      switch (change) {
        case 'profile':
          page.container.read(currentProfileIdProvider.notifier).value = 2;
        case 'url':
          page.container
              .read(profilesProvider.notifier)
              .put(
                _profile.copyWith(
                  url: 'https://panel.example.com/s/ReplacementToken0123456789',
                ),
              );
        case 'dispose':
          page.shown.value = false;
      }
      await tester.pumpAndSettle();
      panel.reply.complete((200, '{"ok":true,"revoked":false}', null));
      await tester.pumpAndSettle();
      expect(page.container.read(vpsRemovedProvider), {1, 2});
      expect(page.setup.requests, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('third-party subscriptions do not show a device recheck', (
    tester,
  ) async {
    final panel = _Panel();
    await _pumpNotice(
      tester,
      panel,
      profile: _profile.copyWith(url: 'https://example.com/subscription.yaml'),
      member: (_) async => null,
    );
    expect(find.text('Check again'), findsNothing);
    expect(panel.bases, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached account data cannot enable checking while refreshing', (
    tester,
  ) async {
    final panel = _Panel();
    final nextMember = Completer<VpsMemberResult?>();
    final page = await _pumpNotice(
      tester,
      panel,
      member: (ref) async => ref.watch(currentProfileIdProvider) == 1
          ? _member
          : nextMember.future,
    );
    expect(find.text('Check again'), findsOneWidget);
    page.container.read(currentProfileIdProvider.notifier).value = 2;
    await tester.pumpAndSettle();
    final refreshing = page.container.read(vpsMemberProvider);
    expect(refreshing.isLoading, isTrue);
    expect(refreshing.value?.member, isNotNull);
    expect(find.text('Check again'), findsNothing);
    expect(panel.bases, isEmpty);
    nextMember.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('Check again'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
