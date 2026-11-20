import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/mine.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

class _Actions extends ProfilesAction {
  var imports = 0;
  var refreshes = 0;
  var allRefreshes = 0;

  @override
  Future<void> addProfileFromLink(
    String link, {
    String? label,
    String ageSecretKey = '',
  }) async {
    imports++;
  }

  @override
  Future<void> updateProfiles() async {
    allRefreshes++;
    throw StateError('refresh all failed');
  }

  @override
  Future<void> updateProfile(
    Profile profile, {
    bool showLoading = false,
    bool reapply = true,
  }) async {
    refreshes++;
    throw StateError('refresh failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUp(() {
    loadAppLocalizations(const Locale('en'));
    globalState.appEnv = 'test';
    globalState.packageInfo = PackageInfo(
      appName: 'vps2vpn',
      packageName: 'test.vps2vpn',
      version: '1.0.0',
      buildNumber: '1',
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    container.dispose();
  });

  Future<_Actions> pumpPage(
    WidgetTester tester, {
    List<Profile> profiles = const [],
  }) async {
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles(profiles)),
        profilesActionProvider.overrideWith(_Actions.new),
        vpsMemberProvider.overrideWith((ref) async => null),
      ],
    );
    globalState.container = container;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(locale: Locale('en'), child: VpsMePage()),
      ),
    );
    await tester.pumpAndSettle();
    return container.read(profilesActionProvider.notifier) as _Actions;
  }

  void paste(WidgetTester tester) {
    tester
        .widget<VpsButton>(find.widgetWithText(VpsButton, 'From clipboard'))
        .onTap!();
  }

  for (final text in ['', 'https://example.com/subscription']) {
    testWidgets('a late clipboard result cannot access a removed page: $text', (
      tester,
    ) async {
      final response = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') return response.future;
            return null;
          });
      final action = await pumpPage(tester);
      paste(tester);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      response.complete({'text': text});
      await tester.pump();
      await tester.pump();

      expect(action.imports, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('clipboard failures are reported without an unhandled future', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            throw PlatformException(
              code: 'denied',
              message: 'clipboard denied',
            );
          }
          return null;
        });
    final action = await pumpPage(tester);
    paste(tester);
    await tester.pumpAndSettle();

    expect(action.imports, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh callbacks collect failures for both entry points', (
    tester,
  ) async {
    final action = await pumpPage(
      tester,
      profiles: const [
        Profile(
          id: 1,
          label: 'Line',
          type: ProfileType.url,
          url: 'https://example.com/subscription',
          autoUpdateDuration: Duration.zero,
        ),
      ],
    );
    tester
        .widget<VpsPressable>(
          find
              .ancestor(
                of: find.text('Update all'),
                matching: find.byType(VpsPressable),
              )
              .first,
        )
        .onTap!();
    await tester.pumpAndSettle();
    final card = find
        .ancestor(of: find.text('Line'), matching: find.byType(VpsCard))
        .first;
    tester
        .widget<VpsPressable>(
          find.descendant(of: card, matching: find.byType(VpsPressable)).last,
        )
        .onTap!();
    await tester.pumpAndSettle();

    expect(action.allRefreshes, 0);
    expect(action.refreshes, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('extreme subscription metadata keeps date and progress valid', (
    tester,
  ) async {
    const maximum = 9223372036854775807;
    await pumpPage(
      tester,
      profiles: const [
        Profile(
          id: 1,
          label: 'Extreme',
          autoUpdateDuration: Duration.zero,
          subscriptionInfo: SubscriptionInfo(
            upload: maximum,
            download: maximum,
            total: maximum,
            expire: 9000000000000,
          ),
        ),
      ],
    );

    expect(tester.takeException(), isNull);
    final card = find
        .ancestor(of: find.text('Extreme'), matching: find.byType(VpsCard))
        .first;
    expect(
      tester
          .widget<FractionallySizedBox>(
            find.descendant(
              of: card,
              matching: find.byType(FractionallySizedBox),
            ),
          )
          .widthFactor,
      1.0,
    );
    expect(find.textContaining('Expires '), findsNothing);
    final usage = find.descendant(
      of: card,
      matching: find.byWidgetPredicate(
        (widget) => widget is Text && (widget.data?.endsWith(' used') ?? false),
      ),
    );
    expect(usage, findsOneWidget);
    expect(tester.widget<Text>(usage).data, isNot(startsWith('-')));
  });
}
