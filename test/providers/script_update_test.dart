import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_paths.dart';
import '../helpers/test_profiles.dart';

class _MemoryScripts extends Scripts {
  _MemoryScripts(this.initial);

  final List<Script> initial;

  @override
  Stream<List<Script>> build() => Stream.value(initial);

  @override
  void put(Script script) {
    final items = state.value ?? [];
    state = AsyncData([
      for (final item in items) item.id == script.id ? script : item,
      if (!items.any((item) => item.id == script.id)) script,
    ]);
  }

  @override
  void del(int id) {
    state = AsyncData([
      for (final item in state.value ?? <Script>[])
        if (item.id != id) item,
    ]);
  }
}

class _NoopSetup extends SetupAction {
  @override
  void applyProfileDebounce({bool silence = false, bool force = false}) {}
}

class _Download {
  _Download(this.options);

  final RequestOptions options;
  final response = Completer<ResponseBody>();

  void complete(String content) =>
      response.complete(ResponseBody.fromString(content, 200));
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
  late _Downloads downloads;
  late HttpClientAdapter originalAdapter;
  late Script script;
  late File savedFile;
  var disposed = false;

  setUp(() async {
    loadAppLocalizations(const Locale('en'));
    home = await Directory.systemTemp.createTemp('script_update_test');
    await useAppPaths(home);
    script = Script(
      id: 1,
      label: 'Original',
      url: 'https://example.com/old',
      lastUpdateTime: DateTime.utc(2026),
    );
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(TestProfiles.new),
        scriptsProvider.overrideWith(() => _MemoryScripts([script])),
        setupActionProvider.overrideWith(_NoopSetup.new),
      ],
    );
    disposed = false;
    globalState.container = container;
    await container.read(scriptsProvider.future);
    savedFile = File(await script.path);
    await savedFile.parent.create(recursive: true);
    await savedFile.writeAsString('existing script');
    originalAdapter = request.downloadDio.httpClientAdapter;
    downloads = _Downloads();
    request.downloadDio.httpClientAdapter = downloads;
  });

  tearDown(() async {
    request.downloadDio.httpClientAdapter = originalAdapter;
    if (!disposed) container.dispose();
    await home.delete(recursive: true);
  });

  List<Script> scripts() => container.read(scriptsProvider).value ?? [];

  test(
    'a refresh reads the stored source and preserves later metadata',
    () async {
      final action = container.read(scriptsActionProvider.notifier);
      final edited = script.copyWith(url: 'https://example.com/new');
      action.putScript(edited);
      final pending = action.updateScript(script);
      final download = await downloads.next();
      expect(download.options.uri.path, '/new');
      container
          .read(scriptsProvider.notifier)
          .put(edited.copyWith(label: 'Renamed', order: 7));
      download.complete('new script');
      await pending;

      expect(scripts().single.url, edited.url);
      expect(scripts().single.label, 'Renamed');
      expect(scripts().single.order, 7);
      expect(
        scripts().single.lastUpdateTime.isAfter(script.lastUpdateTime),
        isTrue,
      );
      expect(await savedFile.readAsString(), 'new script');
      expect(savedFile.parent.listSync().map((entry) => entry.path), [
        savedFile.path,
      ]);
    },
  );

  test(
    'deleting during a download cannot recreate a script or its file',
    () async {
      final action = container.read(scriptsActionProvider.notifier);
      final pending = action.updateScript(script);
      final download = await downloads.next();
      action.deleteScript(script.id);
      await savedFile.delete();
      download.complete('obsolete script');
      await pending;

      expect(scripts(), isEmpty);
      expect(await savedFile.exists(), isFalse);
    },
  );

  test('an edited source wins when an older download finishes last', () async {
    final action = container.read(scriptsActionProvider.notifier);
    final older = action.updateScript(script);
    final oldDownload = await downloads.next();
    final edited = script.copyWith(
      url: 'https://example.com/new',
      label: 'Edited',
    );
    action.putScript(edited);
    final newer = action.updateScript(edited);
    final newDownload = await downloads.next();
    newDownload.complete('new source');
    await newer;
    oldDownload.complete('old source');
    await older;

    expect(scripts().single.url, edited.url);
    expect(scripts().single.label, edited.label);
    expect(await savedFile.readAsString(), 'new source');
  });

  test(
    'the latest refresh wins even when both requests use the same URL',
    () async {
      final action = container.read(scriptsActionProvider.notifier);
      final older = action.updateScript(script);
      final oldDownload = await downloads.next();
      final newer = action.updateScript(script);
      (await downloads.next()).complete('newer response');
      await newer;
      oldDownload.complete('older response');
      await older;

      expect(await savedFile.readAsString(), 'newer response');
      expect(scripts(), hasLength(1));
    },
  );

  test(
    'a failed edited URL stays saved and preserves the previous file',
    () async {
      final action = container.read(scriptsActionProvider.notifier);
      final edited = script.copyWith(url: 'https://example.com/new');
      action.putScript(edited);
      final pending = action.updateScript(edited);
      final outcome = expectLater(pending, throwsA(isA<DioException>()));
      (await downloads.next()).response.completeError(
        const SocketException('offline'),
      );
      await outcome;

      expect(scripts().single, edited);
      expect(await savedFile.readAsString(), 'existing script');
    },
  );

  test(
    'errors from a removed script do not affect a later operation',
    () async {
      final action = container.read(scriptsActionProvider.notifier);
      final pending = action.updateScript(script);
      final download = await downloads.next();
      action.deleteScript(script.id);
      download.response.completeError(const SocketException('offline'));
      await pending;

      expect(scripts(), isEmpty);
      expect(await savedFile.readAsString(), 'existing script');
    },
  );

  test('disposing the owner while downloading prevents publication', () async {
    final pending = container
        .read(scriptsActionProvider.notifier)
        .updateScript(script);
    final download = await downloads.next();
    container.dispose();
    disposed = true;
    download.complete('disposed owner');
    await pending;

    expect(await savedFile.readAsString(), 'existing script');
  });

  test(
    'revocation after staging leaves old bytes and no staging directory',
    () async {
      var checks = 0;
      final updated = await script.save(
        'must not publish',
        shouldCommit: () => ++checks == 1,
      );

      expect(checks, 2);
      expect(updated, script);
      expect(await savedFile.readAsString(), 'existing script');
      expect(savedFile.parent.listSync().map((entry) => entry.path), [
        savedFile.path,
      ]);
    },
  );

  test(
    'a publication failure removes staging without deleting the target',
    () async {
      final blocked = script.copyWith(id: 2);
      final target = Directory(await blocked.path);
      await target.create();
      final marker = File.fromUri(target.uri.resolve('keep'));
      await marker.writeAsString('keep');

      await expectLater(
        blocked.save('replacement'),
        throwsA(isA<FileSystemException>()),
      );

      expect(await marker.readAsString(), 'keep');
      expect(savedFile.parent.listSync().map((entry) => entry.path).toSet(), {
        savedFile.path,
        target.path,
      });
    },
  );
}
