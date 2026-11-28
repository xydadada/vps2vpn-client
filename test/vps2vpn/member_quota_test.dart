import 'dart:convert';

import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/outbound_ip.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/routed_probe.dart';
import 'package:fl_clash/providers/service_status.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/account.dart';
import 'package:fl_clash/vps2vpn/devices.dart';
import 'package:fl_clash/vps2vpn/home.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/mine.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:fl_clash/vps2vpn/tun_ready.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

const _gb = 1024 * 1024 * 1024;
const _maxExactInteger = 9007199254740991;
const _profile = Profile(id: 1, autoUpdateDuration: Duration.zero);

class _Ips extends OutboundIpProbe {
  @override
  RoutedProbeState<String, IpInfo> build() => const RoutedProbeState();

  @override
  void watch(String target) {}

  @override
  void unwatch(String target) {}
}

class _Services extends ServiceStatus {
  @override
  RoutedProbeState<ServiceTarget, ServiceCheck> build() =>
      const RoutedProbeState();

  @override
  void watch(ServiceTarget target) {}

  @override
  void unwatch(ServiceTarget target) {}
}

class _Removed extends VpsRemoved {
  @override
  Set<int> build() => const {};
}

VpsMember _member(String quota) => VpsMember.fromJson(
  jsonDecode(
        '{"name":"Example account","enabled":true,"used_up":1024,'
        '"quota_gb":10,"quota_eff":$quota}',
      )
      as Map<String, Object?>,
);

Future<void> _pump(
  WidgetTester tester,
  Widget child,
  VpsMember? member, {
  Profile profile = _profile,
}) async {
  tester.view.physicalSize = const Size(1100, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      profilesProvider.overrideWith(() => TestProfiles([profile])),
      currentProfileProvider.overrideWithValue(profile),
      currentGroupsStateProvider.overrideWithValue(
        const GroupsState(value: []),
      ),
      isStartProvider.overrideWithValue(false),
      outboundIpProbeProvider.overrideWith(_Ips.new),
      serviceStatusProvider.overrideWith(_Services.new),
      vpsRemovedProvider.overrideWith(_Removed.new),
      vpsTunReadyProvider.overrideWith((ref) async => true),
      vpsMemberProvider.overrideWith(
        (ref) async => member == null ? null : VpsMemberResult(member: member),
      ),
    ],
  );
  addTearDown(container.dispose);
  globalState.container = container;
  await container.read(vpsMemberProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TestApp(
        includeNavigatorKey: false,
        locale: const Locale('en'),
        child: child,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  test('finite JSON quotas cannot overflow the byte conversion', () {
    for (final value in ['1e100', '1e308', '1.7976931348623157e308']) {
      final member = _member(value);
      expect(member.quotaGb.isFinite, isTrue);
      expect(member.quotaBytes, isNull);
      expect(member.unlimited, isFalse);
    }
  });

  test('byte quotas stop at the portable exact integer boundary', () {
    VpsMember withQuota(double quota) =>
        VpsMember(name: 'Example', enabled: true, quotaGb: quota);
    expect(withQuota(_maxExactInteger / _gb).quotaBytes, _maxExactInteger);
    expect(withQuota((_maxExactInteger + 1) / _gb).quotaBytes, isNull);
    expect(withQuota(double.infinity).quotaBytes, isNull);
    expect(withQuota(double.nan).quotaBytes, isNull);
  });

  test('ordinary, exhausted and unlimited quota semantics stay unchanged', () {
    expect(_member('10.5').quotaBytes, (10.5 * _gb).round());
    final exhausted = _member('0');
    expect(exhausted.quotaBytes, 0);
    expect(exhausted.unlimited, isFalse);
    expect(_member('-1').quotaBytes, 0);
    final unlimited = VpsMember.fromJson({'quota_gb': 0, 'quota_eff': 0});
    expect(unlimited.quotaBytes, 0);
    expect(unlimited.unlimited, isTrue);
  });

  testWidgets('the account card shows an unknown quota without crashing', (
    tester,
  ) async {
    await _pump(
      tester,
      const SingleChildScrollView(child: VpsAccountCard()),
      _member('1e308'),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Example account'), findsOneWidget);
    expect(find.text('Used 1 KB · quota unknown'), findsOneWidget);
    expect(find.textContaining('unlimited'), findsNothing);
    expect(find.byType(FractionallySizedBox), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the home data tile keeps an unknown quota neutral', (
    tester,
  ) async {
    await _pump(tester, const VpsHomePage(), _member('1e308'));
    expect(tester.takeException(), isNull);
    expect(find.text('Data left'), findsOneWidget);
    expect(find.text('Quota unknown'), findsOneWidget);
    expect(find.text('This session'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (upload, download, left, percentage) in const [
    (9223372036854775807, 9223372036854775807, '0', '0%'),
    (-500, 250, '750', '75%'),
  ]) {
    testWidgets('third-party usage $upload / $download stays bounded', (
      tester,
    ) async {
      await _pump(
        tester,
        const VpsHomePage(),
        null,
        profile: _profile.copyWith(
          subscriptionInfo: SubscriptionInfo(
            total: 1000,
            upload: upload,
            download: download,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Data left'), findsOneWidget);
      expect(find.text(left), findsOneWidget);
      expect(find.text(percentage), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final (upload, download, ratio) in const [
    (9223372036854775807, 9223372036854775807, 1.0),
    (-500, 250, 0.25),
  ]) {
    testWidgets('the subscription card bounds usage $upload / $download', (
      tester,
    ) async {
      await _pump(
        tester,
        const VpsMePage(),
        null,
        profile: _profile.copyWith(
          subscriptionInfo: SubscriptionInfo(
            total: 1000,
            upload: upload,
            download: download,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final usage = find.textContaining('of 1000 B');
      expect(usage, findsOneWidget);
      final card = find.ancestor(of: usage, matching: find.byType(VpsCard));
      final bar = tester.widget<FractionallySizedBox>(
        find.descendant(of: card, matching: find.byType(FractionallySizedBox)),
      );
      expect(bar.widthFactor, ratio);
      expect(find.textContaining('Used -'), findsNothing);
      if (download == 250) {
        expect(find.text('Used 250 B of 1000 B'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
