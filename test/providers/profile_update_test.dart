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
  @override
  void applyProfileDebounce({bool silence = false, bool force = false}) {}
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
  late _Downloads downloads;
  late HttpClientAdapter originalAdapter;
  late Profile profile;
  late File savedFile;

  setUp(() async {
    loadAppLocalizations(const Locale('en'));
    home = await Directory.systemTemp.createTemp('profile_update_test');
    await useAppPaths(home);
    core = _MockCore();
    when(() => core.validateConfig(any())).thenAnswer((_) async => null);
    profile = Profile.normal(
      label: 'Original',
      url: 'https://example.com/old',
    );
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles([profile])),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        setupActionProvider.overrideWith(_NoopSetup.new),
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
}
