import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/app_update.dart';
import 'package:fl_clash/common/release_asset.dart';
import 'package:fl_clash/models/models.dart';
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
  VpsMemberResult? result, {
  String? subscription,
}) async {
  await tester.pumpWidget(
    TestApp(
      // A fresh scope per pump, so a new override takes effect.
      key: UniqueKey(),
      includeNavigatorKey: false,
      locale: const Locale('en'),
      overrides: [
        vpsMemberProvider.overrideWith((ref) async => result),
        // The real one loads the saved profiles (and leaves timers behind).
        currentProfileProvider.overrideWithValue(
          subscription == null ? null : Profile.normal(url: subscription),
        ),
      ],
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

Future<VpsClientRelease?> Function({
  required bool installed,
  int? proxyPort,
  String? proxyAuth,
})
_gitHub(Object? answer) =>
    ({required installed, proxyPort, proxyAuth}) async => switch (answer) {
      final VpsClientRelease r => r,
      final Exception e => throw e,
      _ => null,
    };

VpsClientRelease _onGitHub(String v) => vpsReleaseFromGitHub({
  'tag_name': 'v$v',
  'html_url': 'https://github.com/$vpsReleaseRepository/releases/tag/v$v',
}, installed: false)!;

void main() {
  final realAsset = resolveSelfUpdateAsset;
  final realGitHub = vpsGitHubLookup;
  setUp(() {
    resolveSelfUpdateAsset = () => null;
    vpsGitHubLookup = _gitHub(null);
  });
  tearDown(() {
    resolveSelfUpdateAsset = realAsset;
    vpsGitHubLookup = realGitHub;
  });

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
    expect(find.text('12 days left'), findsOneWidget);
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
    // And what to do about it.
    expect(
      find.textContaining('Disconnect your other devices'),
      findsOneWidget,
    );
  });

  testWidgets('opens the member centre only for a vps2vpn link', (
    tester,
  ) async {
    const member = VpsMemberResult(
      member: VpsMember(name: 'Ann', enabled: false, disabledReason: 'quota'),
    );
    final button = find.byKey(const ValueKey('vps-member-centre'));
    await _pump(
      tester,
      const VpsAccountCard(),
      member,
      subscription: 'https://panel.example:8443/s/abcdefghijklmnop',
    );
    expect(button, findsOneWidget);
    expect(find.text('Open member centre'), findsOneWidget);
    await _pump(
      tester,
      const VpsAccountCard(),
      member,
      subscription: 'https://example.com/other/sub',
    );
    expect(button, findsNothing);
  });

  test('tells a member whom the panel will not carry, and why', () {
    VpsMemberResult off(String? reason) => VpsMemberResult(
      member: VpsMember(name: 'Ann', enabled: false, disabledReason: reason),
    );
    expect(vpsAccountBlock(null), isNull);
    expect(
      vpsAccountBlock(
        const VpsMemberResult(member: VpsMember(name: 'Ann', enabled: true)),
      ),
      isNull,
    );
    expect(
      vpsAccountBlock(
        const VpsMemberResult(problem: VpsPanelProblem.unreachable),
      ),
      isNull,
    );
    expect(
      vpsAccountBlock(const VpsMemberResult(linkChanged: true)),
      VpsAccountBlock.linkChanged,
    );
    expect(vpsAccountBlock(off('quota')), VpsAccountBlock.quota);
    expect(vpsAccountBlock(off('expired')), VpsAccountBlock.expired);
    expect(vpsAccountBlock(off('devices')), VpsAccountBlock.devices);
    expect(vpsAccountBlock(off('manual')), VpsAccountBlock.manual);
    expect(vpsAccountBlock(off(null)), VpsAccountBlock.manual);
  });

  testWidgets('the last day reads "today", never "0 days left"', (
    tester,
  ) async {
    final now = DateTime(2026, 11, 22, 9);
    late BuildContext context;
    await _pump(
      tester,
      Builder(
        builder: (c) {
          context = c;
          return const SizedBox();
        },
      ),
      null,
    );
    expect(
      vpsExpiryText(context, now.add(const Duration(hours: 5)), now: now),
      'Expires today',
    );
    expect(
      vpsExpiryText(
        context,
        now.add(const Duration(days: 3, hours: 1)),
        now: now,
      ),
      '3 days left',
    );
    expect(
      vpsExpiryText(
        context,
        now.subtract(const Duration(minutes: 1)),
        now: now,
      ),
      'Expired',
    );
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
          url: Uri.parse(
            'https://example.com/vps2vpn-$v-${Platform.operatingSystem}-amd64.zip',
          ),
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
    expect(find.text('Version 1.1.0 is available'), findsNothing);
    expect(find.text('Version and updates'), findsOneWidget);
  });

  testWidgets('a release page opens in the browser; another platform is hidden', (
    tester,
  ) async {
    VpsMemberResult withClient(VpsClientRelease r) => VpsMemberResult(
      member: VpsMember(name: 'Ann', enabled: true, client: r),
    );
    await _pump(
      tester,
      const VpsUpdateCard(currentVersion: '1.0.0'),
      withClient(
        VpsClientRelease(
          version: '1.1.0',
          url: Uri.parse('https://example.com/releases/latest'),
        ),
      ),
    );
    expect(find.text('Open download page'), findsOneWidget);
    expect(find.textContaining('download page'), findsWidgets);
    // Only another platform's installer: nothing this device can use (#67).
    final other = Platform.isAndroid ? 'windows' : 'android';
    final file = Uri.parse(
      'https://example.com/vps2vpn-1.1.0-$other-arm64.${other == 'android' ? 'apk' : 'exe'}',
    );
    await _pump(
      tester,
      const VpsUpdateCard(currentVersion: '1.0.0'),
      withClient(
        VpsClientRelease(version: '1.1.0', url: file, files: {other: file}),
      ),
    );
    expect(find.text('Version 1.1.0 is available'), findsNothing);
    expect(find.text('Version and updates'), findsOneWidget);
  });

  group('updates are no server needed for updates', () {
    Future<void> check(WidgetTester tester) async {
      await tester.tap(find.text('Check now'));
      await tester.pumpAndSettle();
    }

    testWidgets('a subscription that is not a vps2vpn server still gets them', (
      tester,
    ) async {
      vpsGitHubLookup = _gitHub(_onGitHub('1.2.0'));
      await _pump(
        tester,
        const VpsUpdateCard(currentVersion: '1.0.0'),
        null,
        subscription: 'https://provider.example.com/clash.yaml',
      );
      expect(find.text('Version and updates'), findsOneWidget);
      expect(find.textContaining('Not checked yet'), findsOneWidget);
      await check(tester);
      expect(find.text('Version 1.2.0 is available'), findsOneWidget);
    });

    testWidgets('a panel without a client field leaves the answer to GitHub', (
      tester,
    ) async {
      await _pump(
        tester,
        const VpsUpdateCard(currentVersion: '1.0.0'),
        const VpsMemberResult(member: VpsMember(name: 'Ann', enabled: true)),
      );
      await check(tester);
      expect(find.textContaining('Up to date'), findsOneWidget);
      vpsGitHubLookup = _gitHub(_onGitHub('1.3.0'));
      await check(tester);
      expect(find.text('Version 1.3.0 is available'), findsOneWidget);
    });

    testWidgets('GitHub out of reach says so, and the panel mirror stands in', (
      tester,
    ) async {
      vpsGitHubLookup = _gitHub(const SocketException('unreachable'));
      await _pump(tester, const VpsUpdateCard(currentVersion: '1.0.0'), null);
      await check(tester);
      expect(find.textContaining('Check failed'), findsOneWidget);
      expect(find.text('Check now'), findsOneWidget);

      await _pump(
        tester,
        const VpsUpdateCard(currentVersion: '1.0.0'),
        VpsMemberResult(
          member: VpsMember(
            name: 'Ann',
            enabled: true,
            client: VpsClientRelease(
              version: '1.1.0',
              url: Uri.parse('https://example.com/releases/latest'),
            ),
          ),
        ),
      );
      expect(find.text('Version 1.1.0 is available'), findsOneWidget);
    });

    testWidgets('GitHub out of reach, the panel still says up to date', (
      tester,
    ) async {
      vpsGitHubLookup = _gitHub(const SocketException('unreachable'));
      await _pump(
        tester,
        const VpsUpdateCard(currentVersion: '1.0.0'),
        const VpsMemberResult(member: VpsMember(name: 'Ann', enabled: true)),
      );
      await check(tester);
      expect(find.textContaining('Check failed'), findsNothing);
      expect(
        find.textContaining('the subscription server confirmed it'),
        findsOneWidget,
      );
    });

    testWidgets('the newer of GitHub and the mirror wins', (tester) async {
      vpsGitHubLookup = _gitHub(_onGitHub('1.4.0'));
      await _pump(
        tester,
        const VpsUpdateCard(currentVersion: '1.0.0'),
        VpsMemberResult(
          member: VpsMember(
            name: 'Ann',
            enabled: true,
            client: VpsClientRelease(
              version: '1.1.0',
              url: Uri.parse('https://example.com/releases/latest'),
            ),
          ),
        ),
      );
      expect(find.text('Version 1.1.0 is available'), findsOneWidget);
      // The background check found a newer one on GitHub.
      ProviderScope.containerOf(tester.element(find.byType(VpsUpdateCard)))
          .read(vpsUpdateCheckProvider.notifier)
          .set(
            VpsUpdateCheck(
              status: VpsUpdateStatus.available,
              at: DateTime.now(),
              releases: [_onGitHub('1.4.0')],
            ),
          );
      await tester.pumpAndSettle();
      expect(find.text('Version 1.4.0 is available'), findsOneWidget);
    });

    test('reads the latest GitHub release for this build', () {
      final json = {
        'tag_name': 'v1.2.0',
        'html_url':
            'https://github.com/$vpsReleaseRepository/releases/tag/v1.2.0',
        'assets': [
          {
            'name': 'vps2vpn-1.2.0-windows-amd64-setup.exe',
            'browser_download_url': 'https://example.com/a/setup.exe',
          },
        ],
      };
      final installed = vpsReleaseFromGitHub(json, installed: true)!;
      expect(installed.version, '1.2.0');
      expect(
        installed.files['windows'].toString(),
        'https://example.com/a/setup.exe',
      );
      final portable = vpsReleaseFromGitHub(json, installed: false)!;
      expect(
        portable.files['windows']!.path,
        '/$vpsReleaseRepository/releases/download/v1.2.0/'
        'vps2vpn-1.2.0-windows-amd64-portable.zip',
      );
      expect(
        vpsReleaseFromGitHub({...json, 'prerelease': true}, installed: true),
        isNull,
      );
      expect(
        vpsReleaseFromGitHub({'tag_name': 'test-1.2.0'}, installed: true),
        isNull,
      );
    });
  });

  test('a platform map key cannot spoof the signed installer OS', () {
    final android = Uri.parse(
      'https://example.com/vps2vpn-1.1.0-android-arm64.apk',
    );
    final release = VpsClientRelease(
      version: '1.1.0',
      url: android,
      files: {'windows': android, 'android': android},
    );
    expect(release.installerFor('windows'), isNull);
    expect(release.installerFor('android'), android);
    expect(release.pageFor('windows'), isNull);

    // A later "-windows-" substring cannot turn an Android file into Windows.
    final misleading = Uri.parse(
      'https://example.com/vps2vpn-1.1.0-android-arm64-windows-setup.exe',
    );
    expect(
      VpsClientRelease(
        version: '1.1.0',
        url: misleading,
      ).installerFor('windows'),
      isNull,
    );
    final windows = Uri.parse(
      'https://example.com/vps2vpn-1.1.0-windows-amd64-setup.exe',
    );
    expect(
      VpsClientRelease(version: '1.1.0', url: windows).installerFor('windows'),
      windows,
    );
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

  group('the background check', () {
    final realFetcher = vpsUpdateFetcher;
    tearDown(() {
      vpsUpdateFetcher = realFetcher;
      resetVpsAutoUpdate();
    });

    // Run [body] with a WidgetRef of an app whose panel offers 1.1.0, or
    // with no vps2vpn panel at all.
    Future<void> withRef(
      WidgetTester tester,
      Future<void> Function(WidgetRef ref, ProviderContainer c) body, {
      bool panel = true,
    }) async {
      late WidgetRef captured;
      final release = VpsClientRelease(
        version: '1.1.0',
        url: Uri.parse(
          'https://example.com/client/vps2vpn-1.1.0-${Platform.operatingSystem}-amd64-setup.exe',
        ),
      );
      await tester.pumpWidget(
        TestApp(
          key: UniqueKey(),
          includeNavigatorKey: false,
          locale: const Locale('en'),
          overrides: [
            vpsMemberProvider.overrideWith(
              (ref) async => panel
                  ? VpsMemberResult(
                      member: VpsMember(
                        name: 'Ann',
                        enabled: true,
                        client: release,
                      ),
                    )
                  : null,
            ),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              captured = ref;
              return const SizedBox();
            },
          ),
        ),
      );
      await body(
        captured,
        ProviderScope.containerOf(tester.element(find.byType(SizedBox))),
      );
    }

    testWidgets('a download outlives the page that started it (C11-02)', (
      tester,
    ) async {
      resolveSelfUpdateAsset = () => _asset(ReleaseOs.windows);
      final done = Completer<File>();
      vpsUpdateFetcher =
          (
            container,
            url, {
            required install,
            required current,
            onProgress,
          }) async {
            final file = await done.future;
            container.read(appSettingProvider);
            return file;
          };
      final shown = ValueNotifier(true);
      addTearDown(shown.dispose);
      late WidgetRef page;
      await tester.pumpWidget(
        TestApp(
          includeNavigatorKey: false,
          wrapInProviderScope: true,
          locale: const Locale('en'),
          child: ValueListenableBuilder<bool>(
            key: const ValueKey('page'),
            valueListenable: shown,
            builder: (context, on, _) => on
                ? Consumer(
                    builder: (context, ref, _) {
                      page = ref;
                      return const SizedBox();
                    },
                  )
                : const SizedBox.shrink(),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const ValueKey('page'))),
      );
      final settled = vpsDownloadPanelUpdate(
        page,
        VpsClientRelease(
          version: '1.1.0',
          url: Uri.parse(
            'https://example.com/client/vps2vpn-1.1.0-${Platform.operatingSystem}-amd64-setup.exe',
          ),
        ),
        current: '1.0.0',
        auto: true,
      );
      shown.value = false;
      await tester.pump();
      done.complete(File('setup.exe'));

      expect(await settled, isTrue);
      expect(tester.takeException(), isNull);
      final download = container.read(updateDownloadStateProvider.notifier);
      expect(download.value, isA<UpdateReady>());
      download.value = null;
    });

    testWidgets('fetches a newer signed installer and offers to install it', (
      tester,
    ) async {
      resolveSelfUpdateAsset = () => _asset(ReleaseOs.windows);
      final fetched = <Uri>[];
      vpsUpdateFetcher =
          (ref, url, {required install, required current, onProgress}) async {
            fetched.add(url);
            expect((install, current), (true, '1.0.0'));
            onProgress?.call(100, 100);
            return File('setup.exe');
          };
      await withRef(tester, (ref, c) async {
        await vpsAutoUpdateCheck(ref, currentVersion: '1.0.0');
        expect(fetched, hasLength(1));
        final state = c.read(updateDownloadStateProvider);
        expect(state, isA<UpdateReady>());
        expect((state as UpdateReady).tag, 'v1.1.0');
        // Ready: the next check does not fetch it again.
        await vpsAutoUpdateCheck(ref, currentVersion: '1.0.0');
        expect(fetched, hasLength(1));
      });
    });

    testWidgets('a transfer that failed is tried again on the next check', (
      tester,
    ) async {
      resolveSelfUpdateAsset = () => _asset(ReleaseOs.windows);
      var calls = 0;
      vpsUpdateFetcher =
          (ref, url, {required install, required current, onProgress}) async {
            calls++;
            throw const SocketException('offline');
          };
      await withRef(tester, (ref, c) async {
        await vpsAutoUpdateCheck(ref, currentVersion: '1.0.0');
        expect(c.read(updateDownloadStateProvider), isNull);
        await vpsAutoUpdateCheck(ref, currentVersion: '1.0.0');
        expect(calls, 2);
      });
    });

    testWidgets('a failed download keeps an update already verified', (
      tester,
    ) async {
      resolveSelfUpdateAsset = () => _asset(ReleaseOs.windows);
      vpsUpdateFetcher =
          (ref, url, {required install, required current, onProgress}) async {
            throw const SocketException('offline');
          };
      await withRef(tester, (ref, c) async {
        const ready = UpdateReady('v1.0.5', 'old-setup.exe');
        c.read(updateDownloadStateProvider.notifier).value = ready;
        await vpsAutoUpdateCheck(ref, currentVersion: '1.0.0');
        expect(c.read(updateDownloadStateProvider), ready);
      });
    });

    testWidgets('another download under way does not use up this try', (
      tester,
    ) async {
      resolveSelfUpdateAsset = () => _asset(ReleaseOs.windows);
      var calls = 0;
      vpsUpdateFetcher =
          (ref, url, {required install, required current, onProgress}) async {
            calls++;
            return File('setup.exe');
          };
      await withRef(tester, (ref, c) async {
        final state = c.read(updateDownloadStateProvider.notifier);
        state.value = const UpdateDownloading('v1.0.5');
        await vpsAutoUpdateCheck(ref, currentVersion: '1.0.0');
        expect(calls, 0);
        state.value = null;
        await vpsAutoUpdateCheck(ref, currentVersion: '1.0.0');
        expect(calls, 1);
      });
    });

    testWidgets('a download of this version under way leaves it for later', (
      tester,
    ) async {
      resolveSelfUpdateAsset = () => _asset(ReleaseOs.windows);
      var calls = 0;
      vpsUpdateFetcher =
          (ref, url, {required install, required current, onProgress}) async {
            calls++;
            return File('setup.exe');
          };
      await withRef(tester, (ref, c) async {
        final state = c.read(updateDownloadStateProvider.notifier);
        // A manual download of 1.1.0 runs, then fails.
        state.value = const UpdateDownloading('v1.1.0');
        await vpsAutoUpdateCheck(ref, currentVersion: '1.0.0');
        expect(calls, 0);
        state.value = null;
        await vpsAutoUpdateCheck(ref, currentVersion: '1.0.0');
        expect(calls, 1);
      });
    });

    testWidgets('a refused installer is tried once per run', (tester) async {
      resolveSelfUpdateAsset = () => _asset(ReleaseOs.windows);
      var calls = 0;
      vpsUpdateFetcher =
          (ref, url, {required install, required current, onProgress}) async {
            calls++;
            throw const VpsUpdateRejected('unsigned');
          };
      await withRef(tester, (ref, c) async {
        await vpsAutoUpdateCheck(ref, currentVersion: '1.0.0');
        await vpsAutoUpdateCheck(ref, currentVersion: '1.0.0');
        expect(calls, 1);
        expect(c.read(updateDownloadStateProvider), isNull);
      });
    });

    testWidgets('a build that cannot install by itself fetches nothing', (
      tester,
    ) async {
      resolveSelfUpdateAsset = () => null; // portable copy, macOS, Linux
      var calls = 0;
      vpsUpdateFetcher =
          (ref, url, {required install, required current, onProgress}) async {
            calls++;
            return File('x');
          };
      await withRef(tester, (ref, c) async {
        await vpsAutoUpdateCheck(ref, currentVersion: '1.0.0');
        expect(calls, 0);
        final check = c.read(vpsUpdateCheckProvider);
        expect(check.status, VpsUpdateStatus.available);
        expect(check.releases.first.version, '1.1.0');
      });
    });

    testWidgets('without a vps2vpn panel the update comes from GitHub', (
      tester,
    ) async {
      resolveSelfUpdateAsset = () => _asset(ReleaseOs.windows);
      final setup = Uri.https(
        'github.com',
        '/$vpsReleaseRepository/releases/download/v1.2.0/'
            'vps2vpn-1.2.0-${Platform.operatingSystem}-amd64-setup.exe',
      );
      vpsGitHubLookup = _gitHub(VpsClientRelease(version: '1.2.0', url: setup));
      final fetched = <Uri>[];
      vpsUpdateFetcher =
          (ref, url, {required install, required current, onProgress}) async {
            fetched.add(url);
            return File('setup.exe');
          };
      await withRef(tester, panel: false, (ref, c) async {
        await vpsAutoUpdateCheck(ref, currentVersion: '1.0.0');
        expect(fetched.single.host, 'github.com');
        expect(
          (c.read(updateDownloadStateProvider) as UpdateReady).tag,
          'v1.2.0',
        );
        c.read(updateDownloadStateProvider.notifier).value = null;
      });
    });

    testWidgets('automatic checks off: no check in the background', (
      tester,
    ) async {
      var asked = 0;
      vpsGitHubLookup = ({required installed, proxyPort, proxyAuth}) async {
        asked++;
        return null;
      };
      await withRef(tester, panel: false, (ref, c) async {
        c
            .read(appSettingProvider.notifier)
            .update((s) => s.copyWith(autoCheckUpdate: false));
        await vpsAutoUpdateCheck(ref, currentVersion: '1.0.0');
        expect(asked, 0);
        expect(c.read(vpsUpdateCheckProvider).status, VpsUpdateStatus.never);
      });
    });
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
              'https://example.com/client/vps2vpn-1.1.0-${Platform.operatingSystem}-amd64-setup.exe',
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

  test('panel pins vouch only for the panel host and port', () {
    final panel = vpsApiBase('https://panel.example:8443/s/abcdefghijklmnop')!;
    expect(
      vpsSameOrigin(panel, Uri.parse('https://panel.example:8443/c/a.exe')),
      isTrue,
    );
    expect(
      vpsSameOrigin(panel, Uri.parse('https://PANEL.example:8443/c/a.exe')),
      isTrue,
    );
    expect(
      vpsSameOrigin(panel, Uri.parse('https://panel.example/c/a.exe')),
      isFalse,
    );
    expect(
      vpsSameOrigin(panel, Uri.parse('https://other.example:8443/c/a.exe')),
      isFalse,
    );
  });
}
