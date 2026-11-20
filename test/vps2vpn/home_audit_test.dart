import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/outbound_ip.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/routed_probe.dart';
import 'package:fl_clash/providers/service_status.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/home.dart';
import 'package:fl_clash/vps2vpn/servers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

class _NoIpProbe extends OutboundIpProbe {
  @override
  RoutedProbeState<String, IpInfo> build() => const RoutedProbeState();

  @override
  void watch(String target) {}

  @override
  void unwatch(String target) {}
}

class _NoServiceProbe extends ServiceStatus {
  @override
  RoutedProbeState<ServiceTarget, ServiceCheck> build() =>
      const RoutedProbeState();

  @override
  void watch(ServiceTarget target) {}

  @override
  void unwatch(ServiceTarget target) {}
}

class _DelayActions extends ProxiesAction {
  var calls = 0;

  @override
  void build() {}

  @override
  Future<void> delayTest(List<Proxy> proxies, [String? testUrl]) async {
    calls++;
  }
}

void main() {
  testWidgets('home bounds subscription dates and traffic arithmetic', (
    tester,
  ) async {
    const maximum = 9223372036854775807;
    const profile = Profile(
      id: 1,
      label: 'Boundary',
      autoUpdateDuration: Duration.zero,
      subscriptionInfo: SubscriptionInfo(
        total: 1,
        upload: maximum,
        download: maximum,
        expire: 9000000000000,
      ),
    );
    final container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles([profile])),
        currentProfileProvider.overrideWith((ref) => profile),
        runTimeProvider.overrideWithBuild((_, _) => null),
        totalTrafficProvider.overrideWithBuild(
          (_, _) => const Traffic(up: maximum, down: maximum),
        ),
        groupsProvider.overrideWithBuild((_, _) => []),
        outboundIpProbeProvider.overrideWith(_NoIpProbe.new),
        serviceStatusProvider.overrideWith(_NoServiceProbe.new),
      ],
    );
    addTearDown(container.dispose);
    globalState.container = container;
    globalState.appEnv = 'test';
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(locale: Locale('en'), child: VpsHomePage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Data left'), findsOneWidget);
    expect(find.text('0B'), findsOneWidget);
    expect(find.textContaining('days left'), findsNothing);
    expect(
      find.text((maximum.toDouble() + maximum.toDouble()).traffic.show),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a disposed frame owner releases the automatic probe slot', (
    tester,
  ) async {
    final actions = _DelayActions();
    final container = ProviderContainer(
      overrides: [proxiesActionProvider.overrideWith(() => actions)],
    );
    addTearDown(container.dispose);
    late WidgetRef widgetRef;
    Widget owner() => UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, child) {
          widgetRef = ref;
          return const SizedBox();
        },
      ),
    );
    const group = Group(
      name: 'audit-disposed-auto-test',
      type: GroupType.Selector,
      all: [Proxy(name: 'Audit node', type: 'vless')],
    );
    await tester.pumpWidget(owner());
    vpsAutoTestOnce(widgetRef, group);
    await tester.pumpWidget(const SizedBox());

    expect(tester.takeException(), isNull);
    expect(actions.calls, 0);

    await tester.pumpWidget(owner());
    vpsAutoTestOnce(widgetRef, group);
    await tester.pump();
    expect(actions.calls, 1);

    vpsAutoTestOnce(widgetRef, group);
    await tester.pump();
    expect(actions.calls, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
