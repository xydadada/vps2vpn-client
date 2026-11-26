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
  Future<CoreLifecycleResult>? _startOperation;
  final _lifecycleTasks = SerialTaskScheduler();
  bool _needsShutdown = false;
  bool _connected = false;
  int _startRevision = 0;
  int _lifecycleRevision = 0;
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

  @override
  Future<CoreLifecycleResult> start() {
    if (_closed) {
      return Future.error(StateError('Core lifecycle is closed'));
    }
    final active = _startOperation;
    if (active != null && _startRevision == _lifecycleRevision) {
      return active;
    }
    final revision = ++_lifecycleRevision;
    _startRevision = revision;
    late final Future<CoreLifecycleResult> operation;
    operation = _lifecycleTasks.run(() => _start(revision)).whenComplete(() {
      if (identical(_startOperation, operation)) _startOperation = null;
    });
    return _startOperation = operation;
  }

  Future<CoreLifecycleResult> _start(int revision) async {
    if (!_isCurrent(revision)) return _superseded(revision);
    if (_connected) {
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.coalesced,
      );
    }
    if (_needsShutdown) {
      await _shutdown();
      if (!_isCurrent(revision)) return _superseded(revision);
    }
    _needsShutdown = true;
    final initializationError = await _service?.init() ?? '';
    if (!_isCurrent(revision)) return _superseded(revision);
    if (initializationError.isNotEmpty) {
      throw StateError(initializationError);
    }
    await globalState.container.read(vpnOptionsProvider.future);
    if (!_isCurrent(revision)) return _superseded(revision);
    _connectedCompleter.complete(true);
    final syncError =
        await _service?.syncState(
          globalState.container.read(sharedStateProvider),
        ) ??
        '';
    if (!_isCurrent(revision)) return _superseded(revision);
    if (syncError.isNotEmpty) {
      await _shutdown();
      throw StateError(syncError);
    }
    _connected = true;
    return CoreLifecycleResult(
      revision: revision,
      outcome: CoreLifecycleOutcome.applied,
    );
  }

  bool _isCurrent(int revision) => revision == _lifecycleRevision;

  CoreLifecycleResult _superseded(int revision) => CoreLifecycleResult(
    revision: revision,
    outcome: CoreLifecycleOutcome.superseded,
  );

  @override
  Future<CoreLifecycleResult> restart() {
    if (_closed) {
      return Future.error(StateError('Core lifecycle is closed'));
    }
    final revision = ++_lifecycleRevision;
    return _lifecycleTasks.run(() async {
      await _stop(revision);
      return _start(revision);
    });
  }

  @override
  Future<CoreLifecycleResult> stop() {
    if (_closed) {
      return Future.error(StateError('Core lifecycle is closed'));
    }
    final revision = ++_lifecycleRevision;
    return _lifecycleTasks.run(() => _stop(revision));
  }

  Future<CoreLifecycleResult> _stop(int revision) async {
    if (!_isCurrent(revision)) return _superseded(revision);
    if (!_needsShutdown) {
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.coalesced,
      );
    }
    await _shutdown();
    return CoreLifecycleResult(
      revision: revision,
      outcome: _isCurrent(revision)
          ? CoreLifecycleOutcome.applied
          : CoreLifecycleOutcome.superseded,
    );
  }

  Future<void> _shutdown() async {
    _connectedCompleter = Completer<bool>();
    _connected = false;
    final stopped = await _service?.shutdown() ?? true;
    if (!stopped) {
      throw StateError('Android Core service shutdown failed');
    }
    _needsShutdown = false;
  }

  @override
  Future<CoreLifecycleResult> close() {
    final active = _closeOperation;
    if (active != null) return active;
    _closed = true;
    final revision = ++_lifecycleRevision;
    // A late init must finish before the terminal listener removal.
    return _closeOperation = _lifecycleTasks.run(() => _stop(revision));
  }

  // The service opens and closes the Core's listeners itself and reports a run
  // that ends, so once it takes the command the Core's own answer is moot.
  @override
  Future<void> startListener() async {
    await _ignoreUnanswered(super.startListener);
    if (!await _service!.start()) {
      throw const CoreMethodException(
        code: 'service_refused',
        message: 'The Android service did not start',
      );
    }
  }

  @override
  Future<void> stopListener() async {
    final serviceStopped = await _service!.stop();
    await _ignoreUnanswered(super.stopListener);
    if (!serviceStopped) {
      throw const CoreMethodException(
        code: 'service_refused',
        message: 'The Android service did not stop',
      );
    }
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
    try {
      await _connectedCompleter.future.timeout(coreConnectionWaitDuration);
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
