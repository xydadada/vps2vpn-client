@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/app_paths.dart';
import '../helpers/test_profiles.dart';

class _MockCore extends Mock implements CoreHandlerInterface {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides? originalHttpOverrides;

  late Directory home;
  late HttpServer server;
  late ProviderContainer container;
  late _MockCore core;
  late Map<String, Completer<void>> responseGates;
  late Map<String, Completer<void>> requested;
  var disposed = false;

  setUpAll(() async {
    originalHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    loadAppLocalizations(const Locale('en'));
    registerFallbackValue(
      const SetupParams(
        selectedMap: {},
        options: CoreOptions(testUrl: ''),
      ),
    );
    globalState.packageInfo = PackageInfo(
      appName: 'test',
      packageName: 'fl_clash',
      version: '1.0.0',
      buildNumber: '1',
    );
    home = await Directory.systemTemp.createTemp('profile-update-order-');
    await useAppPaths(home);
  });

  tearDownAll(() async {
    HttpOverrides.global = originalHttpOverrides;
    await home.delete(recursive: true);
  });

  setUp(() async {
    disposed = false;
    core = _MockCore();
    when(() => core.validateConfig(any())).thenAnswer((_) async => null);
    when(() => core.clearEffect(any())).thenAnswer((_) async {});
    when(() => core.setupConfig(any())).thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(TestProfiles.new),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        safeModeProvider.overrideWithValue(true),
        setupStateProvider.overrideWith(
          (_, _) => const SetupState(
            profileId: null,
            profileLastUpdateDate: null,
            profileType: ProfileType.file,
            rules: [],
            proxyGroups: [],
            addedRules: [],
            script: null,
            overrides: ProfileOverrides(),
          ),
        ),
      ],
    );
    globalState.container = container;
    request.attach(container.read);
    responseGates = {};
    requested = {};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
      requested[path]?.complete();
      await responseGates[path]?.future;
      req.response.headers.set(
        'subscription-userinfo',
        'upload=${path == '/new' ? 2 : 1}; download=0; total=100',
      );
      req.response.write('proxies: []\n# $path\n');
      try {
        await req.response.close();
      } on SocketException {
        // A failed assertion may close the server before its pending response.
      } on HttpException {
        // A failed assertion may close the server before its pending response.
      }
    });
  });

  tearDown(() async {
    for (final gate in responseGates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await server.close(force: true);
    if (!disposed) container.dispose();
  });

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  Future<Profile> seed() async {
    final profile = await Profile.normal(label: 'P', url: url('/old')).saveFile(
      Uint8List.fromList('original'.codeUnits),
      validate: (_, _) async => null,
    );
    container.read(profilesProvider.notifier).put(profile);
    return profile;
  }

  Future<String> content(Profile profile) async =>
      (await profile.file).readAsString();

  ({Future<void> entered, Completer<String?> result}) holdOldValidation() {
    final entered = Completer<void>();
    final result = Completer<String?>();
    when(() => core.validateConfig(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.single as String;
      if ((await File(path).readAsString()).contains('# /old')) {
        entered.complete();
        return result.future;
      }
      return null;
    });
    addTearDown(() {
      if (!result.isCompleted) result.complete(null);
    });
    return (entered: entered.future, result: result);
  }

  test('a late older download cannot replace the newer source', () async {
    final profile = await seed();
    responseGates['/old'] = Completer<void>();
    requested['/old'] = Completer<void>();
    final action = container.read(profilesActionProvider.notifier);
    final old = action.updateProfile(profile);
    await requested['/old']!.future;

    await action.updateProfile(profile.copyWith(url: url('/new')));
    responseGates['/old']!.complete();
    await old;

    final latest = container.read(profilesProvider).single;
    expect(latest.url, url('/new'));
    expect(latest.subscriptionInfo!.upload, 2);
    expect(await content(latest), contains('# /new'));
  });

  test('a late older validation cannot replace the newer config', () async {
    final profile = await seed();
    final validation = holdOldValidation();
    final action = container.read(profilesActionProvider.notifier);
    final old = action.updateProfile(profile);
    await validation.entered;

    await action.updateProfile(profile.copyWith(url: url('/new')));
    validation.result.complete(null);
    await old;

    final latest = container.read(profilesProvider).single;
    expect(latest.url, url('/new'));
    expect(latest.subscriptionInfo!.upload, 2);
    expect(await content(latest), contains('# /new'));
    expect(
      Directory(await appPath.profilesPath).listSync().whereType<Directory>(),
      isEmpty,
    );
  });

  test('editing source metadata cancels a download before commit', () async {
    final profile = await seed();
    final validation = holdOldValidation();
    final old = container
        .read(profilesActionProvider.notifier)
        .updateProfile(profile);
    await validation.entered;

    container
        .read(profilesProvider.notifier)
        .put(profile.copyWith(url: url('/new')));
    validation.result.complete(null);
    await old;

    expect(container.read(profilesProvider).single.url, url('/new'));
    expect(await content(profile), 'original');
  });

  test('deletion during validation cannot resurrect a file', () async {
    final profile = await seed();
    final validation = holdOldValidation();
    final action = container.read(profilesActionProvider.notifier);
    final old = action.updateProfile(profile);
    await validation.entered;

    await action.deleteProfile(profile.id);
    validation.result.complete(null);
    await old;

    expect(container.read(profilesProvider), isEmpty);
    expect(
      await File(await appPath.getProfilePath(profile.id.toString())).exists(),
      isFalse,
    );
    expect(
      Directory(await appPath.profilesPath).listSync().whereType<Directory>(),
      isEmpty,
    );
  });

  test('disposing the owner cancels a pending commit', () async {
    final profile = await seed();
    final validation = holdOldValidation();
    final old = container
        .read(profilesActionProvider.notifier)
        .updateProfile(profile);
    await validation.entered;

    container.dispose();
    disposed = true;
    validation.result.complete(null);
    await old;

    expect(await content(profile), 'original');
  });

  for (final change in ['source', 'selection', 'delete']) {
    test('missing-file recovery stops after a $change change', () async {
      final profile = Profile.normal(label: 'missing', url: url('/old'));
      final profiles = container.read(profilesProvider.notifier);
      profiles.put(profile);
      container.listen(currentProfileIdProvider, (_, _) {});
      container.read(currentProfileIdProvider.notifier).value = profile.id;
      final validation = holdOldValidation();
      final pending = container
          .read(setupActionProvider.notifier)
          .applyProfile(force: true);
      await validation.entered;

      switch (change) {
        case 'source':
          profiles.put(profile.copyWith(url: url('/new')));
        case 'selection':
          final replacement = Profile.normal(label: 'other');
          profiles.put(replacement);
          container.read(currentProfileIdProvider.notifier).value =
              replacement.id;
        case 'delete':
          await profiles.del(profile.id);
          await deleteProfileFile(profile.id);
      }
      validation.result.complete(null);
      expect(await pending, isFalse);
      expect(
        await File(
          await appPath.getProfilePath(profile.id.toString()),
        ).exists(),
        isFalse,
      );
      if (change == 'source') {
        expect(container.read(profilesProvider).single.url, url('/new'));
      } else if (change == 'delete') {
        expect(container.read(profilesProvider), isEmpty);
      }
      verifyNever(() => core.setupConfig(any()));
    });
  }

  for (final change in ['delete', 'source']) {
    test('a delayed source edit stops after a $change change', () async {
      final profile = await seed();
      final action = container.read(profilesActionProvider.notifier);
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final pending = action.saveProfileEdit(
        profile,
        profile.copyWith(url: url('/new')),
        beforeRefresh: () => gate.future,
      );
      if (change == 'delete') {
        await action.deleteProfile(profile.id);
      } else {
        container
            .read(profilesProvider.notifier)
            .put(profile.copyWith(url: url('/latest')));
      }
      gate.complete();

      expect(await pending, isFalse);
      if (change == 'delete') {
        expect(container.read(profilesProvider), isEmpty);
        expect(
          await File(
            await appPath.getProfilePath(profile.id.toString()),
          ).exists(),
          isFalse,
        );
      } else {
        expect(container.read(profilesProvider).single.url, url('/latest'));
        expect(await content(profile), 'original');
      }
      verifyNever(() => core.validateConfig(any()));
    });
  }

  test(
    'the current source edit refreshes and preserves later metadata',
    () async {
      final profile = await seed();
      final action = container.read(profilesActionProvider.notifier);
      final gate = Completer<void>();
      final pending = action.saveProfileEdit(
        profile,
        profile.copyWith(url: url('/new')),
        beforeRefresh: () => gate.future,
      );
      container
          .read(profilesProvider.notifier)
          .put(profile.copyWith(label: 'renamed while closing'));
      gate.complete();
      expect(await pending, isTrue);
      final latest = container.read(profilesProvider).single;
      expect(latest.label, 'renamed while closing');
      expect(latest.url, url('/new'));
      expect(await content(latest), contains('# /new'));
    },
  );

  for (final change in ['delete', 'source', 'owner']) {
    test('a pending file edit stops after a $change change', () async {
      final profile = await seed();
      final validation = holdOldValidation();
      final action = container.read(profilesActionProvider.notifier);
      var ownerAlive = true;
      final pending = action.saveProfileEdit(
        profile,
        profile.copyWith(label: 'edited'),
        bytes: Uint8List.fromList('edited\n# /old\n'.codeUnits),
        canCommit: () => ownerAlive,
      );
      await validation.entered;
      switch (change) {
        case 'delete':
          await action.deleteProfile(profile.id);
        case 'source':
          container
              .read(profilesProvider.notifier)
              .put(profile.copyWith(url: url('/new')));
        case 'owner':
          ownerAlive = false;
      }
      validation.result.complete(null);

      expect(await pending, isFalse);
      if (change == 'delete') {
        expect(container.read(profilesProvider), isEmpty);
        expect(
          await File(
            await appPath.getProfilePath(profile.id.toString()),
          ).exists(),
          isFalse,
        );
      } else {
        expect(await content(profile), 'original');
        expect(container.read(profilesProvider).single.label, profile.label);
      }
    });
  }

  test('a file edit preserves concurrent metadata changes', () async {
    final profile = await seed();
    final validation = holdOldValidation();
    final pending = container
        .read(profilesActionProvider.notifier)
        .saveProfileEdit(
          profile,
          profile.copyWith(label: 'edited'),
          bytes: Uint8List.fromList('edited\n# /old\n'.codeUnits),
        );
    await validation.entered;
    container
        .read(profilesProvider.notifier)
        .put(
          profile.copyWith(
            label: 'later rename',
            selectedMap: {'group': 'node'},
          ),
        );
    validation.result.complete(null);

    expect(await pending, isTrue);
    final saved = container.read(profilesProvider).single;
    expect(saved.label, 'later rename');
    expect(saved.selectedMap, {'group': 'node'});
    expect(saved.lastUpdateDate, isNotNull);
    expect(await content(profile), 'edited\n# /old\n');
  });

  test('editing a local key never downloads an empty source URL', () async {
    final profile = Profile.normal(label: 'local');
    container.read(profilesProvider.notifier).put(profile);
    final saved = await container
        .read(profilesActionProvider.notifier)
        .saveProfileEdit(
          profile,
          profile.copyWith(ageSecretKey: 'AGE-SECRET-KEY-1LOCAL'),
        );
    expect(saved, isTrue);
    expect(
      container.read(profilesProvider).single.ageSecretKey,
      'AGE-SECRET-KEY-1LOCAL',
    );
    verifyNever(() => core.validateConfig(any()));
  });

  test(
    'rename uses current metadata and cannot recreate a deleted profile',
    () async {
      final profile = await seed();
      final action = container.read(profilesActionProvider.notifier);
      container
          .read(profilesProvider.notifier)
          .put(profile.copyWith(url: url('/new')));
      action.renameProfile(profile.id, 'new label');
      final latest = container.read(profilesProvider).single;
      expect(latest.url, url('/new'));
      expect(latest.label, 'new label');

      await action.deleteProfile(profile.id);
      action.renameProfile(profile.id, 'late rename');
      expect(container.read(profilesProvider), isEmpty);
    },
  );

  test('the first update can create a new profile', () async {
    final profile = Profile.normal(label: 'new', url: url('/new'));
    await container
        .read(profilesActionProvider.notifier)
        .updateProfile(profile);

    final saved = container.read(profilesProvider).single;
    expect(saved.id, profile.id);
    expect(saved.subscriptionInfo!.upload, 2);
    expect(await content(saved), contains('# /new'));
  });
}
