import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/route_state.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';

import '../helpers/test_profiles.dart';

class _Core extends Mock implements CoreHandlerInterface {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Core core;
  late ProviderContainer container;
  late ProxiesAction action;
  late List<String> sent;
  late List<Completer<ChangeProxyResult>> replies;

  setUpAll(() {
    registerFallbackValue(
      const ChangeProxyParams(groupName: 'Proxy', proxyName: 'Old'),
    );
    loadAppLocalizations(const Locale('en'));
  });

  setUp(() {
    core = _Core();
    sent = [];
    replies = [];
    when(() => core.changeProxy(any())).thenAnswer((invocation) {
      sent.add(
        (invocation.positionalArguments.single as ChangeProxyParams).proxyName,
      );
      final reply = Completer<ChangeProxyResult>();
      replies.add(reply);
      return reply.future;
    });
    when(core.closeConnections).thenAnswer((_) async => true);
    when(core.resetConnections).thenAnswer((_) async => true);
    container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        profilesProvider.overrideWith(
          () => TestProfiles([
            const Profile(
              id: 1,
              autoUpdateDuration: defaultUpdateDuration,
              selectedMap: {'Proxy': 'Old'},
            ),
            const Profile(
              id: 2,
              autoUpdateDuration: defaultUpdateDuration,
              selectedMap: {'Proxy': 'Other'},
            ),
          ]),
        ),
        currentProfileIdProvider.overrideWithBuild((_, _) => 1),
      ],
    );
    container.listen(currentProfileIdProvider, (_, _) {});
    action = container.read(proxiesActionProvider.notifier);
  });

  tearDown(() {
    debouncer.cancel((FunctionTag.changeProxy, 'Proxy'));
    debouncer.cancel(FunctionTag.updateGroups);
    container.dispose();
  });

  String? selected() =>
      container.read(currentProfileProvider)?.selectedMap['Proxy'];

  test(
    'serializes selections and a superseded failure cannot roll back',
    () async {
      final first = action.changeProxy(groupName: 'Proxy', proxyName: 'A');
      await pumpEventQueue();
      final second = action.changeProxy(groupName: 'Proxy', proxyName: 'B');
      await pumpEventQueue();
      expect(sent, ['A']);
      expect(selected(), 'B');

      replies[0].completeError(StateError('first request failed'));
      await first;
      await pumpEventQueue();
      expect(sent, ['A', 'B']);
      expect(selected(), 'B');
      replies[1].complete(const ChangeProxyResult(changed: true));
      await second;

      expect(selected(), 'B');
      expect(container.read(routeTrackerProvider).picks, 1);
    },
  );

  test('a later failure restores the last accepted choice', () async {
    final first = action.changeProxy(groupName: 'Proxy', proxyName: 'A');
    await pumpEventQueue();
    final second = action.changeProxy(groupName: 'Proxy', proxyName: 'B');
    replies[0].complete(const ChangeProxyResult(changed: true));
    await first;
    await pumpEventQueue();

    replies[1].complete(const ChangeProxyResult(message: 'rejected'));
    await second;

    expect(selected(), 'A');
  });

  test('queued choices replaced before dispatch never reach Core', () async {
    final first = action.changeProxy(groupName: 'Proxy', proxyName: 'A');
    await pumpEventQueue();
    final second = action.changeProxy(groupName: 'Proxy', proxyName: 'B');
    final third = action.changeProxy(groupName: 'Proxy', proxyName: 'C');
    replies[0].complete(const ChangeProxyResult(changed: true));
    await first;
    await second;
    await pumpEventQueue();

    expect(sent, ['A', 'C']);
    replies[1].complete(const ChangeProxyResult(changed: true));
    await third;
    expect(selected(), 'C');
  });

  test('a failed reply cannot edit a different active profile', () async {
    final first = action.changeProxy(groupName: 'Proxy', proxyName: 'A');
    await pumpEventQueue();
    container.read(currentProfileIdProvider.notifier).value = 2;
    replies[0].completeError(StateError('old profile request failed'));
    await first;

    expect(selected(), 'Other');
    verifyNever(core.closeConnections);
    verifyNever(core.resetConnections);
  });

  test(
    'a successful old reply cannot reset another profile connections',
    () async {
      final first = action.changeProxy(groupName: 'Proxy', proxyName: 'A');
      await pumpEventQueue();
      container.read(currentProfileIdProvider.notifier).value = 2;
      replies[0].complete(const ChangeProxyResult(changed: true));
      await first;

      expect(selected(), 'Other');
      expect(container.read(routeTrackerProvider).picks, 0);
      verifyNever(core.closeConnections);
      verifyNever(core.resetConnections);
    },
  );

  testWidgets('changing profiles cancels a queued debounce', (tester) async {
    action.changeProxyDebounce('Proxy', 'A');
    container.read(currentProfileIdProvider.notifier).value = 2;
    await tester.pump(const Duration(seconds: 2));

    expect(sent, isEmpty);
    expect(selected(), 'Other');
  });

  test('switching away and back does not revive an old reply', () async {
    final first = action.changeProxy(groupName: 'Proxy', proxyName: 'A');
    await pumpEventQueue();
    container.read(currentProfileIdProvider.notifier).value = 2;
    await pumpEventQueue();
    container.read(currentProfileIdProvider.notifier).value = 1;
    final second = action.changeProxy(groupName: 'Proxy', proxyName: 'B');
    await pumpEventQueue();

    expect(sent, ['A', 'B']);
    replies[1].complete(const ChangeProxyResult(changed: true));
    await second;
    replies[0].completeError(StateError('obsolete request failed'));
    await first;
    expect(selected(), 'B');
  });
}
