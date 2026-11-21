import 'dart:io';

import 'package:fl_clash/common/app_update.dart';
import 'package:fl_clash/common/release_asset.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/account.dart';
import 'package:fl_clash/vps2vpn/auto_update.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child,
  VpsMemberResult? result,
) async {
  await tester.pumpWidget(
    TestApp(
      // A fresh scope per pump, so a new override takes effect.
      key: UniqueKey(),
      includeNavigatorKey: false,
      locale: const Locale('en'),
      overrides: [vpsMemberProvider.overrideWith((ref) async => result)],
      child: SingleChildScrollView(child: child),
    ),
  );
  await tester.pumpAndSettle();
}

/// Text inside the card under test, not the app around it.
Finder _texts() => find.descendant(
  of: find.byType(SingleChildScrollView),
  matching: find.byType(Text),
);

const _gb = 1024 * 1024 * 1024;

SelfUpdateAsset? _asset(ReleaseOs? os) => os == null
    ? null
    : (os: os, arch: ReleaseArch.amd64, form: null, extension: '');

void main() {
  final realAsset = resolveSelfUpdateAsset;
  setUp(() => resolveSelfUpdateAsset = () => null);
  tearDown(() => resolveSelfUpdateAsset = realAsset);

  testWidgets('hidden for subscriptions that are not vps2vpn links', (
    tester,
  ) async {
    await _pump(tester, const VpsAccountCard(), null);
    expect(_texts(), findsNothing);
    await _pump(tester, const VpsServerAiCard(), null);
    expect(_texts(), findsNothing);
  });

  testWidgets('shows usage against the quota and the expiry', (tester) async {
    await _pump(
      tester,
      const VpsAccountCard(),
      VpsMemberResult(
        member: VpsMember(
          name: 'Ann',
          enabled: true,
          usedDown: 2 * _gb,
          quotaGb: 10,
          expireAt: DateTime.now().add(const Duration(days: 12, hours: 1)),
        ),
      ),
    );
    expect(find.text('Ann'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    expect(find.textContaining('Used 2'), findsOneWidget);
    expect(find.text('Expires in 12 days'), findsOneWidget);
  });

  testWidgets('says why the account is off', (tester) async {
    await _pump(
      tester,
      const VpsAccountCard(),
      const VpsMemberResult(
        member: VpsMember(
          name: 'Ann',
          enabled: false,
          disabledReason: 'devices',
        ),
      ),
    );
    expect(find.text('Paused for a while: too many devices'), findsOneWidget);
    expect(find.textContaining('unlimited'), findsOneWidget);
  });

  testWidgets('a replaced link asks for the new one', (tester) async {
    await _pump(
      tester,
      const VpsAccountCard(),
      const VpsMemberResult(linkChanged: true),
    );
    expect(find.text('Your link was replaced'), findsOneWidget);
  });

  testWidgets('lists what the server sees for each AI site', (tester) async {
    await _pump(
      tester,
      const VpsServerAiCard(),
      const VpsMemberResult(
        member: VpsMember(
          name: 'Ann',
          enabled: true,
          ai: VpsAiStatus(
            summary: 'Claude works from this server',
            place: 'Singapore',
            sites: {'claude': 'ok', 'chatgpt': 'blocked'},
          ),
        ),
      ),
    );
    expect(find.text('Seen from your server'), findsOneWidget);
    expect(find.text('Claude works from this server'), findsOneWidget);
    expect(find.text('Claude · OK'), findsOneWidget);
    expect(find.text('ChatGPT · Blocked'), findsOneWidget);
    expect(find.textContaining('Gemini'), findsNothing);
  });

  testWidgets('offers a newer client from the panel, not an older one', (
    tester,
  ) async {
    VpsMemberResult withClient(String v) => VpsMemberResult(
      member: VpsMember(
        name: 'Ann',
        enabled: true,
        client: VpsClientRelease(
          version: v,
          url: Uri.parse('https://example.com/setup.exe'),
        ),
      ),
    );
    await _pump(
      tester,
      const VpsUpdateCard(currentVersion: '1.0.0'),
      withClient('1.1.0'),
    );
    expect(find.text('Version 1.1.0 is available'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    await _pump(
      tester,
      const VpsUpdateCard(currentVersion: '1.2.0'),
      withClient('1.1.0'),
    );
    expect(_texts(), findsNothing);
  });

  test('release links without a matching signed asset remain browser links', () {
    final page = Uri.parse(
      'https://github.com/xydadada/vps2vpn-client/releases/latest',
    );
    expect(
      vpsPlatformInstaller(VpsClientRelease(version: '1.1.0', url: page)),
      isNull,
    );
    final other = Platform.isWindows ? 'android' : 'windows';
    final otherFile = Uri.parse(
      'https://example.com/vps2vpn-1.1.0-$other-amd64-setup.exe',
    );
    expect(
      vpsPlatformInstaller(VpsClientRelease(
        version: '1.1.0',
        url: otherFile,
        files: {other: otherFile},
      )),
      isNull,
    );
    final direct = Uri.parse(
      'https://example.com/vps2vpn-1.1.0-${Platform.operatingSystem}-amd64-portable.zip',
    );
    expect(
      vpsPlatformInstaller(VpsClientRelease(version: '1.1.0', url: direct)),
      direct,
    );
  });

  testWidgets('no platform installer offers the release page, not an update', (
    tester,
  ) async {
    resolveSelfUpdateAsset = () => _asset(ReleaseOs.windows);
    final page = Uri.parse(
      'https://github.com/xydadada/vps2vpn-client/releases/latest',
    );
    await _pump(
      tester,
      const VpsUpdateCard(currentVersion: '1.0.0'),
      VpsMemberResult(
        member: VpsMember(
          name: 'Ann',
          enabled: true,
          client: VpsClientRelease(version: '1.1.0', url: page),
        ),
      ),
    );
    expect(find.text('Open downloads'), findsOneWidget);
    expect(find.textContaining('No installer for this platform'), findsOneWidget);
    expect(find.text('Update'), findsNothing);
  });

  test('installs by itself only what this build can run', () {
    const setup = 'vps2vpn-1.1.0-windows-amd64-setup.exe';
    const zip = 'vps2vpn-1.1.0-windows-amd64-portable.zip';
    const apk = 'vps2vpn-1.1.0-android-arm64.apk';
    resolveSelfUpdateAsset = () => _asset(ReleaseOs.windows);
    expect(vpsSelfInstallable(setup), isTrue);
    expect(vpsSelfInstallable(zip), isFalse);
    expect(vpsSelfInstallable(apk), isFalse);
    resolveSelfUpdateAsset = () => _asset(ReleaseOs.android);
    expect(vpsSelfInstallable(apk), isTrue);
    expect(vpsSelfInstallable(setup), isFalse);
    // A portable Windows copy, macOS and Linux keep the manual download.
    resolveSelfUpdateAsset = () => null;
    expect(vpsSelfInstallable(setup), isFalse);
    expect(vpsSelfInstallable(apk), isFalse);
  });

  testWidgets('an installed build updates, shows progress and installs', (
    tester,
  ) async {
    resolveSelfUpdateAsset = () => _asset(ReleaseOs.windows);
    await _pump(
      tester,
      const VpsUpdateCard(currentVersion: '1.0.0'),
      VpsMemberResult(
        member: VpsMember(
          name: 'Ann',
          enabled: true,
          client: VpsClientRelease(
            version: '1.1.0',
            url: Uri.parse(
              'https://example.com/client/vps2vpn-1.1.0-windows-amd64-setup.exe',
            ),
          ),
        ),
      ),
    );
    expect(find.text('Update'), findsOneWidget);
    expect(find.textContaining('installs itself'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(VpsUpdateCard)),
    );
    final download = container.read(updateDownloadStateProvider.notifier);
    download.value = const UpdateDownloading(
      'v1.1.0',
      received: 50,
      total: 100,
    );
    await tester.pump();
    expect(find.text('Downloading 50%'), findsOneWidget);
    download.value = const UpdateReady('v1.1.0', 'setup.exe');
    await tester.pump();
    expect(find.text('Install & restart'), findsOneWidget);
    // A pending update for another version is not this one.
    download.value = const UpdateReady('v1.0.5', 'setup.exe');
    await tester.pump();
    expect(find.text('Update'), findsOneWidget);
    download.value = null;
  });
}
