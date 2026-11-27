import 'dart:async';

import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/servers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

class _Core extends Mock implements CoreHandlerInterface {
  final calls = <ServiceCheckParams>[];
  final pending = <Completer<List<ServiceCheckItem>>>[];

  @override
  Future<List<ServiceCheckItem>> serviceCheck(ServiceCheckParams params) {
    calls.add(params);
    final reply = Completer<List<ServiceCheckItem>>();
    pending.add(reply);
    return reply.future;
  }
}

class _Proxies extends ProxiesAction {
  @override
  void build() {}

  @override
  Future<void> delayTest(List<Proxy> proxies, [String? testUrl]) async {}
}

class _Connection extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool connected) => state = connected;
}

final _connectionProvider = NotifierProvider<_Connection, bool>(
  _Connection.new,
);

const _available = [
  ServiceCheckItem(name: 'claude', status: 'available'),
  ServiceCheckItem(name: 'chatgpt', status: 'available'),
];

Future<({ProviderContainer container, ValueNotifier<bool> shown})> _pumpPage(
  WidgetTester tester,
  _Core core, {
  int nodes = 1,
}) async {
  tester.view.physicalSize = const Size(1100, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final shown = ValueNotifier(true);
  addTearDown(shown.dispose);
  final container = ProviderContainer(
    overrides: [
      profilesProvider.overrideWith(
        () => TestProfiles([
          for (var id = 1; id <= 2; id++)
            Profile(
              id: id,
              label: 'Profile $id',
              autoUpdateDuration: const Duration(hours: 1),
            ),
        ]),
      ),
      currentProfileIdProvider.overrideWithBuild((_, _) => 1),
      currentGroupsStateProvider.overrideWithValue(
        GroupsState(
          value: [
            Group(
              name: 'Main',
              type: GroupType.Selector,
              all: [
                for (var i = 1; i <= nodes; i++)
                  Proxy(name: 'Fixture $i', type: 'Vless'),
              ],
            ),
          ],
        ),
      ),
      selectedProxyNameProvider('Main').overrideWithValue('Fixture 1'),
      isStartProvider.overrideWith((ref) => ref.watch(_connectionProvider)),
      proxiesActionProvider.overrideWith(_Proxies.new),
      coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
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
        child: ValueListenableBuilder<bool>(
          valueListenable: shown,
          builder: (_, visible, _) =>
              visible ? const VpsServersPage() : const SizedBox(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container: container, shown: shown);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await preferences.rebind();
  });

  for (final oldError in [false, true]) {
    testWidgets(
      'a disposed profile check cannot replace the new profile result (error: $oldError)',
      (tester) async {
        final core = _Core();
        final page = await _pumpPage(tester, core);
        await tester.tap(find.text('Test AI'));
        await tester.pumpAndSettle();
        expect(core.calls, hasLength(1));

        page.shown.value = false;
        await tester.pump();
        page.container.read(currentProfileIdProvider.notifier).value = 2;
        page.shown.value = true;
        await tester.pumpAndSettle();
        await tester.tap(find.text('Test AI'));
        await tester.pumpAndSettle();
        expect(core.calls, hasLength(2));
        core.pending[1].complete(_available);
        await tester.pumpAndSettle();
        expect(find.text('AI works'), findsOneWidget);

        if (oldError) {
          core.pending[0].completeError(StateError('old request failed'));
        } else {
          core.pending[0].complete(const []);
        }
        await tester.pumpAndSettle();
        expect(find.text('AI works'), findsOneWidget);
        expect(find.text('No AI'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'switching profiles stops old batches and lets the new profile test',
    (tester) async {
      final core = _Core();
      final page = await _pumpPage(tester, core, nodes: 4);
      await tester.tap(find.text('Test AI'));
      await tester.pumpAndSettle();
      expect(core.calls, hasLength(3));
      page.container.read(currentProfileIdProvider.notifier).value = 2;
      await tester.pumpAndSettle();
      expect(find.text('Test AI'), findsOneWidget);
      await tester.tap(find.text('Test AI'));
      await tester.pumpAndSettle();
      expect(core.calls, hasLength(6));
      for (final reply in core.pending.take(3)) {
        reply.complete(_available);
      }
      await tester.pumpAndSettle();
      expect(core.calls, hasLength(6));
      expect(find.text('AI works'), findsNothing);
      expect(find.text('Test AI'), findsNothing);
      for (final reply in core.pending.skip(3).take(3)) {
        reply.complete(_available);
      }
      await tester.pumpAndSettle();
      core.pending.last.complete(_available);
      await tester.pumpAndSettle();
      expect(core.calls, hasLength(7));
      expect(find.text('AI works'), findsNWidgets(4));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('returning to the same profile does not revive its old check', (
    tester,
  ) async {
    final core = _Core();
    final page = await _pumpPage(tester, core);
    await tester.tap(find.text('Test AI'));
    await tester.pumpAndSettle();
    page.container.read(currentProfileIdProvider.notifier).value = 2;
    await tester.pumpAndSettle();
    page.container.read(currentProfileIdProvider.notifier).value = 1;
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test AI'));
    await tester.pumpAndSettle();
    expect(core.calls, hasLength(2));
    core.pending[1].complete(_available);
    await tester.pumpAndSettle();
    core.pending[0].complete(const []);
    await tester.pumpAndSettle();
    expect(find.text('AI works'), findsOneWidget);
    expect(find.text('No AI'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final change in ['source', 'content']) {
    testWidgets('a profile $change change cancels pending results', (
      tester,
    ) async {
      final core = _Core();
      final page = await _pumpPage(tester, core);
      await tester.tap(find.text('Test AI'));
      await tester.pumpAndSettle();
      final profile = page.container.read(currentProfileProvider)!;
      page.container
          .read(profilesProvider.notifier)
          .put(
            change == 'source'
                ? profile.copyWith(url: 'https://example.com/subscription.yaml')
                : profile.copyWith(lastUpdateDate: DateTime.utc(2026, 11, 27)),
          );
      await tester.pumpAndSettle();
      expect(find.text('Test AI'), findsOneWidget);
      core.pending.single.complete(_available);
      await tester.pumpAndSettle();
      expect(find.text('AI works'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('disconnecting stops pending results and unsent batches', (
    tester,
  ) async {
    final core = _Core();
    final page = await _pumpPage(tester, core, nodes: 4);
    await tester.tap(find.text('Test AI'));
    await tester.pumpAndSettle();
    expect(core.calls, hasLength(3));
    page.container.read(_connectionProvider.notifier).set(false);
    await tester.pumpAndSettle();
    for (final reply in core.pending) {
      reply.complete(_available);
    }
    await tester.pumpAndSettle();
    expect(core.calls, hasLength(3));
    expect(find.text('AI works'), findsNothing);
    expect(find.text('Test AI'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
