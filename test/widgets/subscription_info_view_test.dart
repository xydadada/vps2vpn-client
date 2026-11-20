import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';
import '../helpers/host_scaffold.dart';

void main() {
  for (final detail in [false, true]) {
    testWidgets('invalid persisted expiry stays unknown (detail: $detail)', (
      tester,
    ) async {
      const info = SubscriptionInfo(
        upload: 9223372036854775807,
        download: 1,
        total: 100,
        expire: 8640000000001,
      );
      await tester.pumpWidget(
        HostApp(
          builder: (context, child) => wrapAppScopes(context, child!),
          home: HostScaffold(
            body: SizedBox(
              width: 600,
              child: detail
                  ? const SubscriptionInfoDetailView(subscriptionInfo: info)
                  : const SubscriptionInfoView(subscriptionInfo: info),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text(currentAppLocalizations.unknown), findsOneWidget);
      expect(find.text(currentAppLocalizations.infiniteTime), findsNothing);
      expect(find.textContaining('-'), findsNothing);
    });
  }

  testWidgets('hides expiry when both values do not fit', (tester) async {
    const trafficLabel = '1KB / 1GB';

    await tester.pumpWidget(
      HostApp(
        builder: (context, child) {
          return wrapAppScopes(context, child!);
        },
        home: const HostScaffold(
          body: SizedBox(
            width: 120,
            child: SubscriptionInfoView(
              subscriptionInfo: SubscriptionInfo(
                upload: 1024,
                total: 1073741824,
                expire: 4102444800,
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(trafficLabel), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SubscriptionInfoView),
        matching: find.byType(Text),
      ),
      findsOneWidget,
    );
  });

  testWidgets('keeps expiry at its intrinsic width when both values fit', (
    tester,
  ) async {
    await tester.pumpWidget(
      HostApp(
        builder: (context, child) => wrapAppScopes(context, child!),
        home: const HostScaffold(
          body: SizedBox(
            width: 300,
            child: SubscriptionInfoView(
              subscriptionInfo: SubscriptionInfo(
                upload: 1024,
                total: 1073741824,
                expire: 4102444800,
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byType(SubscriptionInfoView),
        matching: find.byType(Text),
      ),
      findsNWidgets(2),
    );
  });

  testWidgets('shows full subscription details in information rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      HostApp(
        builder: (context, child) {
          return wrapAppScopes(context, child!);
        },
        home: const HostScaffold(
          body: SubscriptionInfoDetailView(
            subscriptionInfo: SubscriptionInfo(
              upload: 1024,
              download: 2048,
              total: 1073741824,
              expire: 4102444800,
            ),
          ),
        ),
      ),
    );

    final appLocalizations = currentAppLocalizations;
    expect(find.text(appLocalizations.trafficUsage), findsOneWidget);
    expect(find.text(appLocalizations.usedTraffic), findsOneWidget);
    expect(find.text(appLocalizations.totalTraffic), findsOneWidget);
    expect(find.text(appLocalizations.expireTime), findsOneWidget);
    expect(find.text('3KB'), findsOneWidget);
    expect(find.text('1GB'), findsOneWidget);
    expect(find.byType(DecorationListItem), findsNWidgets(3));
  });
}
