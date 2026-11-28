import 'dart:async';

import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/lib.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/core/spill.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_profiles.dart';

class _FakeService implements Service {
  _FakeService();

  final calls = <String>[];

  String initError = '';
  String syncError = '';
  Completer<String>? initGate;
  final initEntered = Completer<void>();
  Completer<String>? syncGate;
  Completer<void>? syncEntered;
  bool shutdownResult = true;
  Completer<bool>? shutdownGate;
  Completer<void>? shutdownEntered;
  bool startResult = true;
  bool stopResult = true;
  CoreMethodResponse? Function(CoreMethodCall call)? onInvokeMethod;

  final invokedCalls = <CoreMethodCall>[];

  @override
  Future<String> init() async {
    calls.add('init');
    if (!initEntered.isCompleted) initEntered.complete();
    return initGate?.future ?? initError;
  }

  @override
  Future<String> syncState(SharedState state) async {
    calls.add('syncState');
    syncEntered?.complete();
    return syncGate?.future ?? syncError;
  }

  @override
  Future<bool> shutdown() async {
    calls.add('shutdown');
    shutdownEntered?.complete();
    return shutdownGate?.future ?? shutdownResult;
  }

  @override
  Future<bool> start() async {
    calls.add('start');
    return startResult;
  }

  @override
  Future<bool> stop() async {
    calls.add('stop');
    return stopResult;
  }

  @override
  Future<CoreMethodResponse> invokeMethod(
    CoreMethodCall call, {
    CoreResultModel? model,
  }) async {
    calls.add('invokeMethod:${call.method.wireName}');
    invokedCalls.add(call);
    final response = onInvokeMethod?.call(call);
    if (response == null) {
      throw const CoreMethodException(code: 'no_response', message: '');
    }
    return response;
  }

  @override
  Future<DateTime?> getRunTime() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late _FakeService service;
  late CoreLib lib;

  setUpAll(() async {
    loadAppLocalizations(const Locale('en'));
  });

  setUp(() {
    container = ProviderContainer(
      overrides: [profilesProvider.overrideWith(TestProfiles.new)],
    );
    globalState.container = container;
    service = _FakeService();
    lib = CoreLib.scoped(service);
  });

  tearDown(() {
    container.dispose();
    CoreLib.resetInstance();
  });

  group('start', () {
    test('initializes, connects and syncs shared state', () async {
      final result = await lib.start();

      expect(result.outcome, CoreLifecycleOutcome.applied);
      expect(result.revision, 1);
      expect(service.calls, ['init', 'syncState']);
    });

    test(
      'concurrent starts share initialization and one completion gate',
      () async {
        service.initGate = Completer<String>();

        final first = lib.start();
        final second = lib.start();

        expect(identical(first, second), isTrue);
        await service.initEntered.future;
        expect(service.calls, ['init']);
        service.initGate!.complete('');
        expect((await first).outcome, CoreLifecycleOutcome.applied);
        expect((await second).outcome, CoreLifecycleOutcome.applied);
        expect(service.calls, ['init', 'syncState']);
      },
    );

    test('coalesces a second start while already connected', () async {
      await lib.start();
      service.calls.clear();

      final result = await lib.start();

      expect(result.outcome, CoreLifecycleOutcome.coalesced);
      expect(result.revision, 2);
      expect(service.calls, isEmpty);
    });

    test('an initialization error leaves the handler unconnected', () async {
      service.initError = 'init boom';

      await expectLater(
        lib.start(),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'init boom'),
        ),
      );
      expect(service.calls, ['init']);

      service.initError = '';
      final retry = await lib.start();
      expect(retry.outcome, CoreLifecycleOutcome.applied);
    });

    test('a sync error shuts the service down and reopens the gate', () async {
      service.syncError = 'sync boom';

      await expectLater(
        lib.start(),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'sync boom'),
        ),
      );
      expect(service.calls, ['init', 'syncState', 'shutdown']);

      service.syncError = '';
      service.calls.clear();
      final retry = await lib.start();

      expect(retry.outcome, CoreLifecycleOutcome.applied);
      expect(service.calls, ['init', 'syncState']);
    });
  });

  group('stop', () {
    test('coalesces when there is nothing connected', () async {
      final result = await lib.stop();

      expect(result.outcome, CoreLifecycleOutcome.coalesced);
      expect(service.calls, isEmpty);
    });

    test('shuts the service down once connected', () async {
      await lib.start();
      service.calls.clear();

      final result = await lib.stop();

      expect(result.outcome, CoreLifecycleOutcome.applied);
      expect(service.calls, ['shutdown']);
    });

    test('a failed shutdown leaves cleanup for the next stop', () async {
      await lib.start();
      service.shutdownResult = false;

      await expectLater(lib.stop(), throwsA(isA<StateError>()));

      service.shutdownResult = true;
      final again = await lib.stop();
      expect(again.outcome, CoreLifecycleOutcome.applied);
      expect(service.calls, ['init', 'syncState', 'shutdown', 'shutdown']);
    });
  });

  for (final throwsError in [false, true]) {
    test('a failed shutdown (${throwsError ? 'exception' : 'false'}) '
        'must finish cleanup before another start', () async {
      await lib.start();
      service.calls.clear();
      service.shutdownGate = Completer<bool>();
      service.shutdownEntered = Completer<void>();
      final stopping = lib.stop();
      final failure = expectLater(stopping, throwsA(isA<StateError>()));
      await service.shutdownEntered!.future;
      if (throwsError) {
        service.shutdownGate!.completeError(StateError('shutdown failed'));
      } else {
        service.shutdownGate!.complete(false);
      }
      await failure;

      service.shutdownGate = Completer<bool>();
      service.shutdownEntered = Completer<void>();
      final starting = lib.start();
      await service.shutdownEntered!.future;
      expect(service.calls, ['shutdown', 'shutdown']);
      service.shutdownGate!.complete(true);

      expect((await starting).outcome, CoreLifecycleOutcome.applied);
      expect(service.calls, ['shutdown', 'shutdown', 'init', 'syncState']);
      service.shutdownEntered = null;
      service.shutdownGate = null;
    });
  }

  test('restart stops before starting again', () async {
    await lib.start();
    service.calls.clear();

    final result = await lib.restart();

    expect(result.outcome, CoreLifecycleOutcome.applied);
    expect(service.calls, ['shutdown', 'init', 'syncState']);
  });

  test('a stop during init wins without a later sync', () async {
    service.initGate = Completer<String>();
    final starting = lib.start();
    await service.initEntered.future;
    final stopping = lib.stop();
    service.initGate!.complete('');

    expect((await starting).outcome, CoreLifecycleOutcome.superseded);
    expect((await stopping).outcome, CoreLifecycleOutcome.applied);
    expect(service.calls, ['init', 'shutdown']);
  });

  test(
    'a restart during init finishes old cleanup before starting anew',
    () async {
      final gate = Completer<String>();
      service.initGate = gate;
      final starting = lib.start();
      await service.initEntered.future;
      final restarting = lib.restart();
      service.initGate = null;
      gate.complete('');

      expect((await starting).outcome, CoreLifecycleOutcome.superseded);
      expect((await restarting).outcome, CoreLifecycleOutcome.applied);
      expect(service.calls, ['init', 'shutdown', 'init', 'syncState']);
    },
  );

  test(
    'a newer start overtakes a queued stop without reusing the old start',
    () async {
      final gate = Completer<String>();
      service.initGate = gate;
      final first = lib.start();
      await service.initEntered.future;
      final stopping = lib.stop();
      final latest = lib.start();
      service.initGate = null;
      gate.complete('');

      expect((await first).outcome, CoreLifecycleOutcome.superseded);
      expect((await stopping).outcome, CoreLifecycleOutcome.superseded);
      expect((await latest).outcome, CoreLifecycleOutcome.applied);
      expect(service.calls, ['init', 'shutdown', 'init', 'syncState']);
    },
  );

  test('close overtakes a queued restart without another init', () async {
    final gate = Completer<String>();
    service.initGate = gate;
    final starting = lib.start();
    await service.initEntered.future;
    final restarting = lib.restart();
    final closing = lib.close();
    gate.complete('');

    expect((await starting).outcome, CoreLifecycleOutcome.superseded);
    expect((await restarting).outcome, CoreLifecycleOutcome.superseded);
    expect((await closing).outcome, CoreLifecycleOutcome.applied);
    expect(service.calls, ['init', 'shutdown']);
  });

  group('close', () {
    test('is terminal and rejects later lifecycle intents', () async {
      await lib.start();

      final result = await lib.close();
      expect(result.outcome, CoreLifecycleOutcome.applied);

      await expectLater(lib.start(), throwsA(isA<StateError>()));
      await expectLater(lib.stop(), throwsA(isA<StateError>()));
    });

    test(
      'supersedes initialization and detaches only after it returns',
      () async {
        service.initGate = Completer<String>();
        final starting = lib.start();
        await service.initEntered.future;
        final closing = lib.close();
        var closed = false;
        unawaited(closing.then((_) => closed = true));
        await Future<void>.value();
        expect(closed, isFalse);
        expect(service.calls, ['init']);

        service.initGate!.complete('');

        expect((await starting).outcome, CoreLifecycleOutcome.superseded);
        expect((await closing).outcome, CoreLifecycleOutcome.applied);
        expect(service.calls, ['init', 'shutdown']);
        await expectLater(lib.start(), throwsA(isA<StateError>()));
      },
    );

    test('supersedes a start waiting on VPN options', () async {
      final options = await container.read(vpnOptionsProvider.future);
      container.dispose();
      final gate = Completer<VpnOptions>();
      final waiting = Completer<void>();
      container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(TestProfiles.new),
          vpnOptionsProvider.overrideWith((_) {
            waiting.complete();
            return gate.future;
          }),
        ],
      );
      globalState.container = container;
      final starting = lib.start();
      await waiting.future;
      final closing = lib.close();

      gate.complete(options);

      expect((await starting).outcome, CoreLifecycleOutcome.superseded);
      expect((await closing).outcome, CoreLifecycleOutcome.applied);
      expect(service.calls, ['init', 'shutdown']);
    });

    test('supersedes sync before the final service shutdown', () async {
      service.syncGate = Completer<String>();
      service.syncEntered = Completer<void>();
      final starting = lib.start();
      await service.syncEntered!.future;
      final closing = lib.close();
      service.syncGate!.complete('');

      expect((await starting).outcome, CoreLifecycleOutcome.superseded);
      expect((await closing).outcome, CoreLifecycleOutcome.applied);
      expect(service.calls, ['init', 'syncState', 'shutdown']);
    });

    test('a failed pending init still detaches the service on close', () async {
      service.initGate = Completer<String>();
      final starting = lib.start();
      await service.initEntered.future;
      final closing = lib.close();
      service.initGate!.completeError(StateError('init failed'));

      await expectLater(starting, throwsA(isA<StateError>()));
      expect((await closing).outcome, CoreLifecycleOutcome.applied);
      expect(service.calls, ['init', 'shutdown']);
    });

    test('runs the shutdown once no matter how often it is called', () async {
      await lib.start();
      service.calls.clear();

      final first = lib.close();
      final second = lib.close();

      expect(identical(first, second), isTrue);
      await first;
      await second;

      expect(service.calls, ['shutdown']);
    });
  });

  group('listeners', () {
    test('a listener start is answered by the service', () async {
      await lib.start();
      service.onInvokeMethod = (_) => const CoreMethodResponse(id: '1');

      await lib.startListener();

      service.startResult = false;
      await expectLater(
        lib.startListener(),
        throwsA(
          isA<CoreMethodException>().having(
            (error) => error.code,
            'code',
            'service_refused',
          ),
        ),
      );

      service.startResult = true;
      service.onInvokeMethod = (_) => null;
      await lib.startListener();
      expect(service.calls.last, 'start');
    });

    test('a listener stop is answered by the service', () async {
      await lib.start();
      service.onInvokeMethod = (_) => null;

      await lib.stopListener();

      service.stopResult = false;
      await expectLater(
        lib.stopListener(),
        throwsA(isA<CoreMethodException>()),
      );
    });

    test('a listener command the Core refuses still fails', () async {
      await lib.start();
      service.onInvokeMethod = (call) => CoreMethodResponse(
        id: call.id,
        error: const CoreMethodError(code: 'core_error', message: 'busy'),
      );

      await expectLater(
        lib.startListener(),
        throwsA(isA<CoreMethodException>()),
      );
      expect(service.calls, isNot(contains('start')));
    });

    test('stopListener stops the service before the core listener', () async {
      await lib.start();
      service.onInvokeMethod = (_) => const CoreMethodResponse(id: '1');
      service.calls.clear();

      await lib.stopListener();
      expect(service.calls, ['stop', 'invokeMethod:listener.stop']);
    });
  });

  group('invokeMethod', () {
    test('assigns an increasing call id per request', () async {
      await lib.start();
      service.onInvokeMethod = (call) =>
          CoreMethodResponse(id: call.id, result: 'ok');

      await lib.invokeMethod(method: CoreMethod.proxyList);
      await lib.invokeMethod(method: CoreMethod.proxyList);

      expect(service.invokedCalls.map((call) => call.id), ['1', '2']);
    });

    test('unwraps the response payload', () async {
      await lib.start();
      service.onInvokeMethod = (call) =>
          CoreMethodResponse(id: call.id, result: 'payload');

      expect(await lib.invokeMethod(method: CoreMethod.proxyList), 'payload');
    });

    test('fails when the service answers nothing', () async {
      await lib.start();
      service.onInvokeMethod = (_) => null;

      await expectLater(
        lib.invokeMethod(method: CoreMethod.proxyList),
        throwsA(
          isA<CoreMethodException>().having(
            (error) => error.code,
            'code',
            'no_response',
          ),
        ),
      );
    });

    testWidgets('gives up instead of hanging when no connection arrives', (
      tester,
    ) async {
      Object? failure;
      final pending = lib
          .invokeMethod(method: CoreMethod.proxyList)
          .catchError((Object error) => failure = error);

      await tester.pump(const Duration(seconds: 11));
      await pending;

      expect(
        failure,
        isA<CoreMethodException>().having(
          (error) => error.code,
          'code',
          'core_unavailable',
        ),
      );
      expect(service.calls, isEmpty);
    });
  });
}
