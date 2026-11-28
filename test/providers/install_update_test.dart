import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/update_install.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_paths.dart';
import '../helpers/test_app.dart';

class _Installer extends UpdateInstaller {
  _Installer({this.android = false});

  final bool android;
  final verification = Completer<bool>();
  final package = Completer<int?>();
  final verified = <String>[];
  final launched = <String>[];

  @override
  bool get isAndroid => android;

  @override
  Future<bool> verify(String path) {
    verified.add(path);
    return verification.future;
  }

  @override
  Future<int?> installPackage(String path) {
    launched.add(path);
    return package.future;
  }

  @override
  bool runWindows(String path) {
    launched.add(path);
    return true;
  }
}

class _System extends SystemAction {
  var exits = 0;

  @override
  void build() {}

  @override
  Future<void> handleExit([bool needSave = true]) async => exits++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ready = UpdateReady('v1.0.9', 'fixture-setup.exe');
  const newer = UpdateReady('v1.0.10', 'newer-fixture-setup.exe');
  late Directory dir;
  late _System exit;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('v2v-install-action-');
    await useAppPaths(dir);
    exit = _System();
  });
  tearDown(() => dir.delete(recursive: true));

  ProviderContainer build(_Installer installer, {bool dispose = true}) {
    final container = ProviderContainer(
      overrides: [
        updateInstallerProvider.overrideWithValue(installer),
        systemActionProvider.overrideWith(() => exit),
      ],
    );
    if (dispose) addTearDown(container.dispose);
    globalState.container = container;
    container.read(updateDownloadStateProvider.notifier).value = ready;
    return container;
  }

  test(
    'Windows starts once only after current verification succeeds',
    () async {
      final installer = _Installer();
      final container = build(installer);
      final action = container.read(commonActionProvider.notifier);
      final first = action.installUpdate();
      await action.installUpdate();
      expect(installer.verified, [ready.path]);
      expect(installer.launched, isEmpty);
      expect(exit.exits, 0);

      installer.verification.complete(true);
      await first;
      expect(installer.launched, [ready.path]);
      expect(exit.exits, 1);
    },
  );

  test(
    'discard while checking prevents the old installer from starting',
    () async {
      final installer = _Installer();
      final container = build(installer);
      final action = container.read(commonActionProvider.notifier);
      final pending = action.installUpdate();
      await action.discardUpdate();
      installer.verification.complete(true);
      await pending;
      expect(installer.launched, isEmpty);
      expect(container.read(updateDownloadStateProvider), isNull);
      expect(exit.exits, 0);
    },
  );

  for (final verified in [true, false]) {
    test(
      'a stale $verified verification cannot alter a newer ready update',
      () async {
        final installer = _Installer();
        final container = build(installer);
        final pending = container
            .read(commonActionProvider.notifier)
            .installUpdate();
        container.read(updateDownloadStateProvider.notifier).value = newer;
        installer.verification.complete(verified);
        await pending;
        expect(installer.launched, isEmpty);
        expect(container.read(updateDownloadStateProvider), same(newer));
        expect(exit.exits, 0);
      },
    );
  }

  test('disposal while checking cannot call the installer', () async {
    final installer = _Installer();
    final container = build(installer, dispose: false);
    final pending = container
        .read(commonActionProvider.notifier)
        .installUpdate();
    container.dispose();
    installer.verification.complete(true);
    await pending;
    expect(installer.launched, isEmpty);
    expect(exit.exits, 0);
  });

  test('Android remains single-flight through the package installer', () async {
    final installer = _Installer(android: true);
    final container = build(installer);
    final action = container.read(commonActionProvider.notifier);
    final pending = action.installUpdate();
    installer.verification.complete(true);
    await Future<void>.delayed(Duration.zero);
    await action.installUpdate();
    expect(installer.verified, [ready.path]);
    expect(installer.launched, [ready.path]);
    installer.package.complete(0);
    await pending;
    expect(container.read(updateDownloadStateProvider), isNull);
    expect(exit.exits, 0);
  });

  for (final status in [0, 1]) {
    test(
      'late Android status $status preserves a newer download and its files',
      () async {
        final installer = _Installer(android: true);
        final container = build(installer);
        final pending = container
            .read(commonActionProvider.notifier)
            .installUpdate();
        installer.verification.complete(true);
        await Future<void>.delayed(Duration.zero);
        final folder = await Directory(await appPath.updateDirPath).create();
        final replacement = File('${folder.path}/newer.apk');
        await replacement.writeAsString('new download');
        container.read(updateDownloadStateProvider.notifier).value = newer;
        installer.package.complete(status);
        await pending;
        expect(container.read(updateDownloadStateProvider), same(newer));
        expect(await replacement.readAsString(), 'new download');
        expect(exit.exits, 0);
      },
    );
  }

  testWidgets(
    'a failed current check clears only that update and explains retry',
    (tester) async {
      final installer = _Installer();
      final container = build(installer);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TestApp(locale: Locale('en'), child: SizedBox()),
        ),
      );
      await tester.pumpAndSettle();
      final pending = container
          .read(commonActionProvider.notifier)
          .installUpdate();
      installer.verification.complete(false);
      await tester.pumpAndSettle();
      expect(container.read(updateDownloadStateProvider), isNull);
      expect(installer.launched, isEmpty);
      expect(
        find.textContaining('did not pass its integrity check'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await pending;
      expect(tester.takeException(), isNull);
    },
  );
}
