import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/home.dart';
import 'package:fl_clash/vps2vpn/node_status.dart';
import 'package:fl_clash/vps2vpn/servers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

class _Proxies extends ProxiesAction {
  @override
  void build() {}

  @override
  Future<void> delayTest(List<Proxy> proxies, [String? testUrl]) async {}
}

Future<ProviderContainer> _pumpPage(
  WidgetTester tester, {
  required List<Group> groups,
  String? selected,
  Locale locale = const Locale('en'),
}) async {
  const profile = Profile(
    id: 1,
    label: 'Fixture',
    autoUpdateDuration: Duration(hours: 1),
  );
  final container = ProviderContainer(
    overrides: [
      profilesProvider.overrideWith(() => TestProfiles([profile])),
      currentProfileProvider.overrideWithValue(profile),
      currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
      currentGroupsStateProvider.overrideWithValue(GroupsState(value: groups)),
      for (final group in groups)
        selectedProxyNameProvider(group.name).overrideWithValue(selected),
      isStartProvider.overrideWithValue(false),
      proxiesActionProvider.overrideWith(_Proxies.new),
    ],
  );
  addTearDown(container.dispose);
  globalState.container = container;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TestApp(
        includeNavigatorKey: false,
        locale: locale,
        child: const VpsServersPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await preferences.rebind();
  });

  for (final locale in ['en', 'zh']) {
    for (final selected in [vpsSmartGroupName, 'Fixture node']) {
      testWidgets(
        '$locale smart line identifies whether it is selected: $selected',
        (tester) async {
          tester.view.physicalSize = const Size(1100, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await _pumpPage(
            tester,
            locale: Locale(locale),
            selected: selected,
            groups: const [
              Group(
                name: 'Main',
                type: GroupType.Selector,
                all: [
                  Proxy(name: vpsSmartGroupName, type: 'URLTest'),
                  Proxy(name: 'Fixture node', type: 'Vless'),
                ],
              ),
            ],
          );
          final active = locale == 'en' ? 'In use · auto' : '使用中 · 自动选最快';
          final idle = locale == 'en' ? 'Picks the fastest' : '推荐 · 自动选最快';
          expect(
            find.text(
              selected == vpsSmartGroupName ? active : idle,
              findRichText: true,
            ),
            findsOneWidget,
          );
          expect(
            find.text(
              selected == vpsSmartGroupName ? idle : active,
              findRichText: true,
            ),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'resizing reveals the selected group without undoing manual scroll',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = await _pumpPage(
        tester,
        groups: [
          for (var i = 1; i <= 8; i++)
            Group(name: 'Region 0$i', type: GroupType.Selector),
        ],
      );
      final horizontal = find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      );
      expect(horizontal, findsNothing);
      await tester.tap(find.text('Region 08'));
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(700, 800);
      await tester.pumpAndSettle();
      expect(horizontal, findsOneWidget);
      final viewport = tester.getRect(horizontal);
      final chosen = tester.getRect(find.text('Region 08'));
      expect(chosen.left, greaterThanOrEqualTo(viewport.left));
      expect(chosen.right, lessThanOrEqualTo(viewport.right));

      final scroll = tester
          .widget<SingleChildScrollView>(horizontal)
          .controller!;
      scroll.jumpTo(0);
      container.read(vpsNodeStatusProvider.notifier).set([
        const VpsNodeStatus(
          group: 'Main',
          names: ['Another node'],
          state: VpsNodeState.congested,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
