import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/dashboard/layout.dart';
import 'package:fl_clash/views/dashboard/widgets/profiles.dart';
import 'package:fl_clash/views/profiles/profiles.dart';
import 'package:fl_clash/views/proxies/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/host_scaffold.dart';
import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

Profile _profile(SubscriptionInfo info) => Profile(
  id: 1,
  type: ProfileType.url,
  label: 'Example subscription',
  url: 'https://example.com/subscription',
  autoUpdateDuration: Duration.zero,
  subscriptionInfo: info,
);

Future<void> _pump(
  WidgetTester tester,
  SubscriptionInfo info,
  Widget child,
) async {
  final profile = _profile(info);
  final container = ProviderContainer(
    overrides: [
      profilesProvider.overrideWith(() => TestProfiles([profile])),
      currentProfileProvider.overrideWithValue(profile),
      viewSizeProvider.overrideWithBuild((_, _) => const Size(1000, 900)),
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
        child: HostScaffold(
          body: SingleChildScrollView(
            child: SizedBox(width: 400, child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  for (final (name, info, used, total, dashboard, ratio) in const [
    (
      'int64 overflow',
      SubscriptionInfo(
        upload: 9223372036854775807,
        download: 9223372036854775807,
        total: 1000,
      ),
      '16777216TB',
      '1000B',
      '16777216 TB / 1000 B',
      1.0,
    ),
    (
      'negative component',
      SubscriptionInfo(upload: -500, download: 250, total: 1000),
      '250B',
      '1000B',
      '250 B / 1000 B',
      0.25,
    ),
    (
      'ordinary counters',
      SubscriptionInfo(upload: 1024, download: 2048, total: 4096),
      '3KB',
      '4KB',
      '3 KB / 4 KB',
      0.75,
    ),
  ]) {
    testWidgets('compact subscription meter handles $name', (tester) async {
      await _pump(tester, info, SubscriptionInfoView(subscriptionInfo: info));
      expect(find.text('$used / $total'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        ratio,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('subscription detail rows handle $name', (tester) async {
      await _pump(
        tester,
        info,
        SubscriptionInfoDetailView(subscriptionInfo: info),
      );
      expect(find.text(used), findsOneWidget);
      expect(find.text(total), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('dashboard subscription card handles $name', (tester) async {
      await _pump(
        tester,
        info,
        const DashboardDensityScope(
          density: DashboardDensity.standard,
          scale: 1,
          child: SizedBox(height: 176, child: ProfilesCard()),
        ),
      );
      expect(find.text(dashboard), findsOneWidget);
      expect(
        find.textContaining('${(ratio * 100).round()}%', findRichText: true),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('profile list subtitle handles $name', (tester) async {
      await _pump(
        tester,
        info,
        ProfileItem(profile: _profile(info), groupValue: 1, onChanged: (_) {}),
      );
      expect(find.text('$used / $total'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('provider traffic meter handles $name', (tester) async {
      await _pump(
        tester,
        info,
        ProviderItem(
          provider: ExternalProvider(
            name: 'Example provider',
            type: 'Proxy',
            count: 1,
            vehicleType: 'HTTP',
            updateAt: DateTime.fromMillisecondsSinceEpoch(0),
            subscriptionInfo: info,
          ),
        ),
      );
      expect(find.text('$used / $total'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        ratio,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final total in [0, -100]) {
    testWidgets('compact meter hides an unavailable quota $total', (
      tester,
    ) async {
      final info = SubscriptionInfo(upload: 100, total: total);
      await _pump(tester, info, SubscriptionInfoView(subscriptionInfo: info));
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining(' / '), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
