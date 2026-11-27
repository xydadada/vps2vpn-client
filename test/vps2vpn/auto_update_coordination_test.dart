import 'dart:async';
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

String _name(String version) =>
    'vps2vpn-$version-${Platform.operatingSystem}-amd64-setup.exe';

VpsClientRelease _release(
  String version, {
  String? fileVersion,
  String? notes,
}) => VpsClientRelease(
  version: version,
  url: Uri.https('updates.example', '/${_name(fileVersion ?? version)}'),
  notes: notes,
);

UpdateReady _ready(String version) => UpdateReady('v$version', _name(version));

class _InstallAction extends CommonAction {
  int calls = 0;

  @override
  Future<void> installUpdate() async {
    calls++;
  }
}

Future<(WidgetRef, ProviderContainer)> _scope(
  WidgetTester tester, {
  _InstallAction? installAction,
  VpsClientRelease? mirror,
  Widget child = const SizedBox(),
}) async {
  late WidgetRef captured;
  const key = ValueKey('update coordination');
  await tester.pumpWidget(
    TestApp(
      includeNavigatorKey: false,
      locale: const Locale('en'),
      overrides: [
        vpsMemberProvider.overrideWith(
          (ref) async => mirror == null
              ? null
              : VpsMemberResult(
                  member: VpsMember(
                    name: 'Example member',
                    enabled: true,
                    client: mirror,
                  ),
                ),
        ),
        if (installAction != null)
          commonActionProvider.overrideWith(() => installAction),
      ],
      child: Consumer(
        key: key,
        builder: (context, ref, _) {
          captured = ref;
          return child;
        },
      ),
    ),
  );
  return (captured, ProviderScope.containerOf(tester.element(find.byKey(key))));
}

void main() {
  final realAsset = resolveSelfUpdateAsset;
  final realLookup = vpsGitHubLookup;
  final realFetcher = vpsUpdateFetcher;
  setUp(() {
    resolveSelfUpdateAsset = () => (
      os: ReleaseOs.windows,
      arch: ReleaseArch.amd64,
      form: null,
      extension: '',
    );
    vpsGitHubLookup = ({required installed, proxyPort, proxyAuth}) async =>
        null;
    vpsUpdateFetcher =
        (
          container,
          url, {
          required install,
          required current,
          onProgress,
        }) async => File(url.pathSegments.last);
  });
  tearDown(() {
    resolveSelfUpdateAsset = realAsset;
    vpsGitHubLookup = realLookup;
    vpsUpdateFetcher = realFetcher;
    resetVpsAutoUpdate();
  });

  testWidgets('manual and automatic checks share the in-flight lookup', (
    tester,
  ) async {
    final (ref, container) = await _scope(tester);
    final answers = [
      Completer<VpsClientRelease?>(),
      Completer<VpsClientRelease?>(),
    ];
    final offers = <String>[];
    final subscription = container.listen(vpsUpdateCheckProvider, (_, check) {
      if (check.status == VpsUpdateStatus.available) {
        offers.add(check.releases.first.version);
      }
    });
    addTearDown(subscription.close);
    var calls = 0;
    vpsGitHubLookup = ({required installed, proxyPort, proxyAuth}) {
      return answers[calls++].future;
    };
    final manual = vpsCheckForUpdateNow(ref, currentVersion: '1.0.0');
    final automatic = vpsAutoUpdateCheck(ref, currentVersion: '1.0.0');
    answers[1].complete(_release('1.3.0'));
    await tester.pump();
    answers[0].complete(_release('1.1.0'));
    await Future.wait([manual, automatic]);

    expect(offers, ['1.1.0']);
    expect(calls, 1);
    await vpsCheckForUpdateNow(ref, currentVersion: '1.0.0');
    expect(
      calls,
      2,
      reason: 'a completed lookup must not prevent later checks',
    );
  });

  testWidgets('an older automatic offer keeps the newer verified installer', (
    tester,
  ) async {
    final (ref, container) = await _scope(tester);
    final ready = _ready('1.2.0');
    container.read(updateDownloadStateProvider.notifier).value = ready;
    vpsGitHubLookup = ({required installed, proxyPort, proxyAuth}) async =>
        _release('1.1.0');
    var fetched = 0;
    vpsUpdateFetcher =
        (
          container,
          url, {
          required install,
          required current,
          onProgress,
        }) async {
          fetched++;
          return File(url.pathSegments.last);
        };

    await vpsAutoUpdateCheck(ref, currentVersion: '1.0.0');

    expect(fetched, 0);
    expect(container.read(updateDownloadStateProvider), same(ready));
  });

  testWidgets('manual offers cannot replace a newer or equal cached version', (
    tester,
  ) async {
    final (ref, container) = await _scope(tester);
    final ready = _ready('1.2.0');
    container.read(updateDownloadStateProvider.notifier).value = ready;
    final fetched = <Uri>[];
    vpsUpdateFetcher =
        (
          container,
          url, {
          required install,
          required current,
          onProgress,
        }) async {
          fetched.add(url);
          return File(url.pathSegments.last);
        };

    for (final version in ['1.1.0', '1.2.0', '1.2']) {
      expect(
        await vpsDownloadPanelUpdate(
          ref,
          _release(version),
          current: '1.0.0',
          auto: true,
        ),
        isTrue,
      );
    }

    expect(fetched, isEmpty);
    expect(container.read(updateDownloadStateProvider), same(ready));
  });

  testWidgets('a higher metadata version cannot disguise an older file', (
    tester,
  ) async {
    final (ref, container) = await _scope(tester);
    final ready = _ready('1.2.0');
    container.read(updateDownloadStateProvider.notifier).value = ready;
    var fetched = 0;
    vpsUpdateFetcher =
        (
          container,
          url, {
          required install,
          required current,
          onProgress,
        }) async {
          fetched++;
          return File(url.pathSegments.last);
        };

    await vpsDownloadPanelUpdate(
      ref,
      _release('9.0.0', fileVersion: '1.1.0'),
      current: '1.0.0',
      auto: true,
    );

    expect(fetched, 0);
    expect(container.read(updateDownloadStateProvider), same(ready));
  });

  testWidgets('a newer installer is checked against the verified version', (
    tester,
  ) async {
    final (ref, container) = await _scope(tester);
    container.read(updateDownloadStateProvider.notifier).value = _ready(
      '1.2.0',
    );
    String? floor;
    vpsUpdateFetcher =
        (
          container,
          url, {
          required install,
          required current,
          onProgress,
        }) async {
          floor = current;
          return File(url.pathSegments.last);
        };

    await vpsDownloadPanelUpdate(
      ref,
      _release('9.0.0', fileVersion: '1.3.0'),
      current: '1.0.0',
      auto: true,
    );

    expect(floor, '1.2.0');
    final ready = container.read(updateDownloadStateProvider) as UpdateReady;
    expect(ready.tag, 'v1.3.0');
    expect(ready.path, _name('1.3.0'));
  });

  testWidgets(
    'both ready views use the cached filename and allow installation',
    (tester) async {
      final action = _InstallAction();
      final (_, container) = await _scope(
        tester,
        installAction: action,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            VpsUpdateCard(currentVersion: '1.0.0'),
            VpsUpdateNotice(),
          ],
        ),
      );
      container
          .read(vpsUpdateCheckProvider.notifier)
          .set(
            VpsUpdateCheck(
              status: VpsUpdateStatus.available,
              releases: [_release('1.1.0', notes: 'Older release notes')],
            ),
          );
      container.read(updateDownloadStateProvider.notifier).value = UpdateReady(
        'v9.0.0',
        _name('1.2.0'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Version 1.2.0 is available'), findsOneWidget);
      expect(
        find.text('Version 1.2.0 is downloaded and its signature checked'),
        findsOneWidget,
      );
      expect(find.textContaining('9.0.0'), findsNothing);
      expect(find.text('Older release notes'), findsNothing);
      expect(find.text('Install & restart'), findsNWidgets(2));
      await tester.tap(find.text('Install & restart').first);
      await tester.pump();
      await tester.tap(find.text('Install & restart').last);
      await tester.pump();
      expect(action.calls, 2);

      container.read(updateDownloadStateProvider.notifier).value =
          const UpdateReady('v9.0.0', 'unknown-file.exe');
      await tester.pumpAndSettle();
      expect(find.textContaining('9.0.0'), findsNothing);
      expect(find.text('Install & restart'), findsNothing);
      expect(find.text('Update'), findsOneWidget);
    },
  );

  testWidgets('a cached installer remains available when the feed is offline', (
    tester,
  ) async {
    final action = _InstallAction();
    final (_, container) = await _scope(
      tester,
      installAction: action,
      child: const VpsUpdateCard(currentVersion: '1.0.0'),
    );
    container
        .read(vpsUpdateCheckProvider.notifier)
        .set(const VpsUpdateCheck(status: VpsUpdateStatus.failed));
    container.read(updateDownloadStateProvider.notifier).value = _ready(
      '1.2.0',
    );
    await tester.pumpAndSettle();

    expect(find.text('Version 1.2.0 is available'), findsOneWidget);
    await tester.tap(find.text('Install & restart'));
    await tester.pump();
    expect(action.calls, 1);
  });

  testWidgets('the offered filename controls the displayed download version', (
    tester,
  ) async {
    final (_, container) = await _scope(
      tester,
      child: const VpsUpdateCard(currentVersion: '1.0.0'),
    );
    container
        .read(vpsUpdateCheckProvider.notifier)
        .set(
          VpsUpdateCheck(
            status: VpsUpdateStatus.available,
            releases: [_release('9.0.0', fileVersion: '1.3.0')],
          ),
        );
    container.read(updateDownloadStateProvider.notifier).value = _ready(
      '1.2.0',
    );
    await tester.pumpAndSettle();

    expect(find.text('Version 1.3.0 is available'), findsOneWidget);
    expect(find.textContaining('9.0.0'), findsNothing);
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(find.text('Install & restart'), findsOneWidget);
    final ready = container.read(updateDownloadStateProvider) as UpdateReady;
    expect(ready.tag, 'v1.3.0');
  });

  testWidgets('matching feed tags do not hide a newer mirrored installer', (
    tester,
  ) async {
    final (_, container) = await _scope(
      tester,
      mirror: _release('9.0.0', fileVersion: '1.3.0'),
      child: const VpsUpdateCard(currentVersion: '1.0.0'),
    );
    container
        .read(vpsUpdateCheckProvider.notifier)
        .set(
          VpsUpdateCheck(
            status: VpsUpdateStatus.available,
            releases: [_release('9.0.0', fileVersion: '1.1.0')],
          ),
        );
    container.read(updateDownloadStateProvider.notifier).value = _ready(
      '1.2.0',
    );
    await tester.pumpAndSettle();

    expect(find.text('Version 1.3.0 is available'), findsOneWidget);
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    final ready = container.read(updateDownloadStateProvider) as UpdateReady;
    expect(ready.path, _name('1.3.0'));
  });
}
