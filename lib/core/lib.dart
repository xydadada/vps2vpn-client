import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'desktop/model.dart';
import 'interface.dart';
import 'method.dart';
import 'spill.dart';

class CoreLib extends CoreHandlerInterface {
  static CoreLib? _instance;

  final Service? _service;

  Completer<bool> _connectedCompleter = Completer<bool>();
  Future<CoreLifecycleResult>? _closeOperation;
  Future<void> _lifecycleTail = Future.value();
  int _lifecycleRevision = 0;
  int _startGeneration = 0;
  int _listenerRevision = 0;
  bool _initialized = false;
  bool _pendingListenerStart = false;
  int _methodCallId = 0;
  bool _closed = false;

  CoreLib._internal() : _service = service;

  @visibleForTesting
  CoreLib.scoped(Service this._service);

  @visibleForTesting
  static void resetInstance() {
    _instance = null;
  }

  factory CoreLib() {
    _instance ??= CoreLib._internal();
    return _instance!;
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _lifecycleTail.then((_) => operation());
    _lifecycleTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  bool _startWanted(int generation) =>
      !_closed && generation == _startGeneration;

  @override
  Future<CoreLifecycleResult> start() {
    if (_closed) {
      return Future.error(StateError('Core lifecycle is closed'));
    }
    final revision = ++_lifecycleRevision;
    final generation = _startGeneration;
    return _enqueue(() => _start(revision, generation));
  }

  Future<CoreLifecycleResult> _start(int revision, int generation) async {
    CoreLifecycleResult superseded() => CoreLifecycleResult(
      revision: revision,
      outcome: CoreLifecycleOutcome.superseded,
    );
    if (!_startWanted(generation)) return superseded();
    if (_connectedCompleter.isCompleted) {
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.coalesced,
      );
    }
    if (_initialized) await _shutdown();
    if (!_startWanted(generation)) return superseded();
    _initialized = true;
    var committed = false;
    try {
      final initializationError = await _service?.init() ?? '';
      if (initializationError.isNotEmpty) {
        throw StateError(initializationError);
      }
      if (!_startWanted(generation)) return superseded();
      await globalState.container.read(vpnOptionsProvider.future);
      if (!_startWanted(generation)) return superseded();
      _connectedCompleter.complete(true);
      final syncError =
          await _service?.syncState(
            globalState.container.read(sharedStateProvider),
          ) ??
          '';
      if (syncError.isNotEmpty) {
        throw StateError(syncError);
      }
      if (!_startWanted(generation)) return superseded();
      committed = true;
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.applied,
      );
    } finally {
      if (!committed) await _shutdown();
    }
  }

  @override
  Future<CoreLifecycleResult> restart() {
    if (_closed) {
      return Future.error(StateError('Core lifecycle is closed'));
    }
    final revision = ++_lifecycleRevision;
    final generation = ++_startGeneration;
    return _enqueue(() async {
      await _stop(revision);
      return _start(revision, generation);
    });
  }

  @override
  Future<CoreLifecycleResult> stop() {
    if (_closed) {
      return Future.error(StateError('Core lifecycle is closed'));
    }
    final revision = ++_lifecycleRevision;
    _startGeneration++;
    return _enqueue(() => _stop(revision));
  }

  Future<void> _shutdown() async {
    final connection = _connectedCompleter;
    _connectedCompleter = Completer<bool>();
    if (!connection.isCompleted) connection.complete(false);
    if (!_initialized) return;
    final stopped = await _service?.shutdown() ?? true;
    if (!stopped) {
      throw StateError('Android Core service shutdown failed');
    }
    _initialized = false;
  }

  Future<CoreLifecycleResult> _stop(int revision) async {
    await _cancelUnconfirmedListenerStart();
    final initialized = _initialized;
    await _shutdown();
    return CoreLifecycleResult(
      revision: revision,
      outcome: initialized
          ? CoreLifecycleOutcome.applied
          : CoreLifecycleOutcome.coalesced,
    );
  }

  @override
  Future<CoreLifecycleResult> close() {
    if (_closeOperation case final pending?) return pending;
    _closed = true;
    _startGeneration++;
    final revision = ++_lifecycleRevision;
    final operation = _enqueue(() => _stop(revision));
    _closeOperation = operation;
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // Keep ownership when shutdown fails, and allow an explicit retry.
          if (identical(_closeOperation, operation)) _closeOperation = null;
        },
      ),
    );
    return operation;
  }

  // The service opens and closes the Core's listeners itself and reports a run
  // that ends, so once it takes the command the Core's own answer is moot.
  @override
  Future<void> startListener() {
    final revision = ++_listenerRevision;
    final generation = _startGeneration;
    bool current() => revision == _listenerRevision && _startWanted(generation);
    void checkCurrent() {
      if (!current() || !_initialized || !_connectedCompleter.isCompleted) {
        throw const CoreMethodException(
          code: 'core_unavailable',
          message: 'Core listener start was superseded',
        );
      }
    }

    return _enqueue(() async {
      checkCurrent();
      final service = _service!;
      final alreadyRunning = await service.getRunTime() != null;
      checkCurrent();
      if (!alreadyRunning) _pendingListenerStart = true;
      try {
        await _ignoreUnanswered(super.startListener);
        checkCurrent();
        if (!await service.start()) {
          throw const CoreMethodException(
            code: 'service_refused',
            message: 'The Android service did not start',
          );
        }
        checkCurrent();
        final running = await service.getRunTime() != null;
        checkCurrent();
        if (running) _pendingListenerStart = false;
      } catch (_) {
        if (!alreadyRunning) {
          await _cancelUnconfirmedListenerStart(force: true);
        }
        rethrow;
      }
    });
  }

  Future<void> _cancelUnconfirmedListenerStart({bool force = false}) async {
    if (!_pendingListenerStart) return;
    final running = !force && await _service!.getRunTime() != null;
    if (!running && !await _service!.stop()) {
      throw const CoreMethodException(
        code: 'service_refused',
        message: 'The pending Android service start did not stop',
      );
    }
    _pendingListenerStart = false;
  }

  @override
  Future<void> stopListener() {
    _listenerRevision++;
    return _enqueue(() async {
      final serviceStopped = await _service!.stop();
      if (serviceStopped) _pendingListenerStart = false;
      await _ignoreUnanswered(super.stopListener);
      if (!serviceStopped) {
        throw const CoreMethodException(
          code: 'service_refused',
          message: 'The Android service did not stop',
        );
      }
    });
  }

  Future<void> _ignoreUnanswered(Future<void> Function() command) async {
    try {
      await command();
    } catch (error) {
      if (!isUnansweredCoreError(error)) {
        rethrow;
      }
    }
  }

  @override
  Future<Object?> invokeMethod({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
    CoreResultModel? model,
  }) {
    final call = _send(method: method, arguments: arguments, model: model);
    return call.withTimeout(
      timeout: timeout,
      onTimeout: () {
        unawaited(call.then(discardSpilledFile, onError: (_) {}));
        throw TimeoutException('Core method ${method.wireName} timed out');
      },
    );
  }

  Future<Object?> _send({
    required CoreMethod method,
    Object? arguments,
    CoreResultModel? model,
  }) async {
    if (_closed) {
      throw const CoreMethodException(
        code: 'core_unavailable',
        message: 'Core lifecycle is closed',
      );
    }
    final connection = _connectedCompleter;
    try {
      final connected = await connection.future.timeout(
        coreConnectionWaitDuration,
      );
      if (!connected ||
          _closed ||
          !identical(connection, _connectedCompleter)) {
        throw const CoreMethodException(
          code: 'core_unavailable',
          message: 'Core connection was superseded',
        );
      }
    } on TimeoutException {
      throw CoreMethodException(
        code: 'core_unavailable',
        message: 'Core is not connected for ${method.wireName}',
      );
    }
    final id = '${++_methodCallId}';
    final response = await _service!.invokeMethod(
      CoreMethodCall(id: id, method: method, arguments: arguments),
      model: model,
    );
    return response.unwrap<Object?>();
  }
}

CoreLib? get coreLib => system.isAndroid ? CoreLib() : null;
