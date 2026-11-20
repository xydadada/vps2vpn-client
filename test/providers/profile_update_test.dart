import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
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

import '../helpers/app_paths.dart';
import '../helpers/test_profiles.dart';

class _MockCore extends Mock implements CoreHandlerInterface {}

class _NoopSetup extends SetupAction {
  int applies = 0;

  @override
  void applyProfileDebounce({bool silence = false, bool force = false}) {
    applies++;
  }
}

class _NoopClashProviders extends ClashProvidersAction {
  @override
  Future<void> applyIfReferenced(
    ProviderKind kind,
    Set<String> labels, {
    bool force = false,
  }) async {}
}

class _Download {
  _Download(this.options);

  final RequestOptions options;
  final response = Completer<ResponseBody>();

  void complete(String contents, {int download = 0}) {
    response.complete(
      ResponseBody.fromString(
        contents,
        200,
        headers: {
          'subscription-userinfo': ['download=$download; total=1000'],
        },
      ),
    );
  }
}

class _Downloads implements HttpClientAdapter {
  final _pending = <_Download>[];
  Completer<_Download>? _waiting;

  Future<_Download> next() {
    if (_pending.isNotEmpty) {
      return Future.value(_pending.removeAt(0));
    }
    return (_waiting = Completer<_Download>()).future.timeout(
      const Duration(seconds: 5),
    );
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final download = _Download(options);
    final waiting = _waiting;
    _waiting = null;
    if (waiting == null) {
      _pending.add(download);
    } else {
      waiting.complete(download);
    }
    return download.response.future;
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory home;
  late ProviderContainer container;
  late _MockCore core;
  late _NoopSetup setup;
  late _Downloads downloads;
  late HttpClientAdapter originalAdapter;
  late Profile profile;
  late File savedFile;

  setUp(() async {
    loadAppLocalizations(const Locale('en'));
    home = await Directory.systemTemp.createTemp('profile_update_test');
    await useAppPaths(home);
    core = _MockCore();
    setup = _NoopSetup();
    when(() => core.validateConfig(any())).thenAnswer((_) async => null);
    profile = Profile.normal(
      label: 'Original',
      url: 'https://example.com/old',
    );
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles([profile])),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        setupActionProvider.overrideWith(() => setup),
        clashProvidersActionProvider.overrideWith(_NoopClashProviders.new),
      ],
    );
    globalState.container = container;
    savedFile = await profile.file;
    await savedFile.writeAsString('existing profile');
    originalAdapter = request.downloadDio.httpClientAdapter;
    downloads = _Downloads();
    request.downloadDio.httpClientAdapter = downloads;
  });

  tearDown(() async {
    request.downloadDio.httpClientAdapter = originalAdapter;
    container.dispose();
    await home.delete(recursive: true);
  });

  test('a delayed refresh reads the stored URL instead of its old snapshot', () async {
    final latest = profile.copyWith(
      url: 'https://example.com/new',
      label: 'Edited',
    );
    container.read(profilesProvider.notifier).put(latest);
    final pending = container
        .read(profilesActionProvider.notifier)
        .updateProfile(profile);
    final download = await downloads.next();
    expect(download.options.uri.path, '/new');
    download.complete('new profile', download: 20);
    await pending;

    final saved = container.read(profilesProvider).single;
    expect(saved.url, latest.url);
    expect(saved.label, latest.label);
    expect(saved.subscriptionInfo?.download, 20);
    expect(saved.lastUpdateDate, isNotNull);
    expect(await savedFile.readAsString(), 'new profile');
  });

  test('deleting a profile during validation cannot publish or recreate it', () async {
    final entered = Completer<void>();
    final validation = Completer<String?>();
    when(() => core.validateConfig(any())).thenAnswer((_) {
      entered.complete();
      return validation.future;
    });
    final pending = container
        .read(profilesActionProvider.notifier)
        .updateProfile(profile);
    (await downloads.next()).complete('deleted profile', download: 30);
    await entered.future;
    await container.read(profilesProvider.notifier).del(profile.id);
    validation.complete(null);
    await pending;

    expect(container.read(profilesProvider), isEmpty);
    expect(await savedFile.readAsString(), 'existing profile');
  });

  test('an edit during validation rejects bytes from the previous source', () async {
    final entered = Completer<void>();
    final validation = Completer<String?>();
    when(() => core.validateConfig(any())).thenAnswer((_) {
      entered.complete();
      return validation.future;
    });
    final pending = container
        .read(profilesActionProvider.notifier)
        .updateProfile(profile);
    (await downloads.next()).complete('obsolete profile', download: 40);
    await entered.future;
    final latest = profile.copyWith(
      url: 'https://example.com/new',
      ageSecretKey: 'new key',
      label: 'Edited',
    );
    container.read(profilesProvider.notifier).put(latest);
    validation.complete(null);
    await pending;

    expect(container.read(profilesProvider).single, latest);
    expect(await savedFile.readAsString(), 'existing profile');
  });

  test('a newer refresh wins even when the older validator finishes last', () async {
    final olderEntered = Completer<void>();
    final olderValidation = Completer<String?>();
    when(() => core.validateConfig(any())).thenAnswer((invocation) async {
      final contents = await File(
        invocation.positionalArguments.single as String,
      ).readAsString();
      if (contents == 'older profile') {
        olderEntered.complete();
        return olderValidation.future;
      }
      return null;
    });
    final action = container.read(profilesActionProvider.notifier);
    final older = action.updateProfile(profile);
    (await downloads.next()).complete('older profile', download: 10);
    await olderEntered.future;
    final newer = action.updateProfile(profile);
    (await downloads.next()).complete('newer profile', download: 90);
    await newer;
    olderValidation.complete(null);
    await older;

    expect(await savedFile.readAsString(), 'newer profile');
    expect(container.read(profilesProvider).single.subscriptionInfo?.download, 90);
    expect(
      savedFile.parent.listSync().whereType<File>().map((file) => file.path),
      [savedFile.path],
    );
  });

  test('an obsolete download error does not report failure for a deleted row', () async {
    final pending = container
        .read(profilesActionProvider.notifier)
        .updateProfile(profile);
    final download = await downloads.next();
    await container.read(profilesProvider.notifier).del(profile.id);
    download.response.completeError(const SocketException('offline'));
    await pending;

    expect(container.read(profilesProvider), isEmpty);
    expect(await savedFile.readAsString(), 'existing profile');
  });

  test('a current download error still reaches the caller', () async {
    final pending = container
        .read(profilesActionProvider.notifier)
        .updateProfile(profile);
    final outcome = expectLater(pending, throwsA(isA<DioException>()));
    final download = await downloads.next();
    download.response.completeError(const SocketException('offline'));
    await outcome;

    expect(container.read(profilesProvider).single, profile);
    expect(await savedFile.readAsString(), 'existing profile');
  });

  test('missing-file repair uses the same ownership as an explicit refresh', () async {
    await savedFile.delete();
    container.read(currentProfileIdProvider.notifier).value = profile.id;
    final entered = Completer<void>();
    final validation = Completer<String?>();
    when(() => core.validateConfig(any())).thenAnswer((invocation) async {
      final contents = await File(
        invocation.positionalArguments.single as String,
      ).readAsString();
      if (contents == 'repair') {
        entered.complete();
        return validation.future;
      }
      return null;
    });
    final action = container.read(profilesActionProvider.notifier);
    final repair = action.updateMissingProfile(profile);
    (await downloads.next()).complete('repair');
    await entered.future;
    final refresh = action.updateProfile(profile);
    (await downloads.next()).complete('newer refresh', download: 70);
    await refresh;
    validation.complete(null);
    await repair;

    expect(await savedFile.readAsString(), 'newer refresh');
    expect(container.read(profilesProvider).single.subscriptionInfo?.download, 70);
    expect(setup.applies, 1);
  });

  test('missing-file repair cannot resurrect a profile deleted during download', () async {
    await savedFile.delete();
    final pending = container
        .read(profilesActionProvider.notifier)
        .updateMissingProfile(profile);
    final download = await downloads.next();
    await container.read(profilesProvider.notifier).del(profile.id);
    download.complete('obsolete');
    await pending;

    expect(container.read(profilesProvider), isEmpty);
    expect(await savedFile.exists(), isFalse);
    expect(setup.applies, 0);
  });

  test('successful missing-file repair does not schedule another setup', () async {
    await savedFile.delete();
    container.read(currentProfileIdProvider.notifier).value = profile.id;
    final pending = container
        .read(profilesActionProvider.notifier)
        .updateMissingProfile(profile);
    (await downloads.next()).complete('repaired');
    await pending;

    expect(await savedFile.readAsString(), 'repaired');
    expect(container.read(profilesProvider).single.lastUpdateDate, isNotNull);
    expect(setup.applies, 0);
  });

  test('saving local bytes supersedes a blocked refresh from the same URL', () async {
    final entered = Completer<void>();
    final validation = Completer<String?>();
    when(() => core.validateConfig(any())).thenAnswer((invocation) async {
      final contents = await File(
        invocation.positionalArguments.single as String,
      ).readAsString();
      if (contents == 'remote') {
        entered.complete();
        return validation.future;
      }
      return null;
    });
    final action = container.read(profilesActionProvider.notifier);
    final remote = action.updateProfile(profile);
    (await downloads.next()).complete('remote', download: 70);
    await entered.future;
    final saved = await action.saveProfileFile(
      profile.copyWith(label: 'Edited'),
      Uint8List.fromList('local'.codeUnits),
    );
    validation.complete(null);
    await remote;

    expect(saved, isTrue);
    expect(await savedFile.readAsString(), 'local');
    expect(container.read(profilesProvider).single.label, 'Edited');
    expect(container.read(profilesProvider).single.subscriptionInfo, isNull);
  });

  test('a superseded local validation cannot replace a newer refresh', () async {
    final entered = Completer<void>();
    final validation = Completer<String?>();
    when(() => core.validateConfig(any())).thenAnswer((invocation) async {
      final contents = await File(
        invocation.positionalArguments.single as String,
      ).readAsString();
      if (contents == 'local') {
        entered.complete();
        return validation.future;
      }
      return null;
    });
    final action = container.read(profilesActionProvider.notifier);
    final local = action.saveProfileFile(
      profile.copyWith(label: 'Obsolete'),
      Uint8List.fromList('local'.codeUnits),
    );
    await entered.future;
    final remote = action.updateProfile(profile);
    (await downloads.next()).complete('new remote', download: 80);
    await remote;
    validation.complete(null);

    expect(await local, isFalse);
    expect(await savedFile.readAsString(), 'new remote');
    expect(container.read(profilesProvider).single.label, 'Original');
    expect(container.read(profilesProvider).single.subscriptionInfo?.download, 80);
  });

  test('local saves preserve selections changed while validation was pending', () async {
    final entered = Completer<void>();
    final validation = Completer<String?>();
    when(() => core.validateConfig(any())).thenAnswer((_) {
      entered.complete();
      return validation.future;
    });
    final pending = container
        .read(profilesActionProvider.notifier)
        .saveProfileFile(
          profile.copyWith(label: 'Edited'),
          Uint8List.fromList('local'.codeUnits),
        );
    await entered.future;
    container.read(profilesProvider.notifier).put(
      profile.copyWith(selectedMap: {'Group': 'New selection'}),
    );
    validation.complete(null);

    expect(await pending, isTrue);
    final latest = container.read(profilesProvider).single;
    expect(latest.label, 'Edited');
    expect(latest.selectedMap, {'Group': 'New selection'});
  });

  test('an editor put invalidates an older refresh even when the URL is unchanged', () async {
    final action = container.read(profilesActionProvider.notifier);
    final pending = action.updateProfile(profile);
    final download = await downloads.next();
    action.putProfile(profile.copyWith(label: 'Edited'));
    download.complete('obsolete');
    await pending;

    expect(await savedFile.readAsString(), 'existing profile');
    expect(container.read(profilesProvider).single.label, 'Edited');
  });
}
