import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/core/desktop/launcher.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('direct launcher decodes split and malformed UTF-8 log chunks', () async {
    final stderr = StreamController<List<int>>();
    final logs = <String>[];
    final previousDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) {
        logs.add(message);
      }
    };
    addTearDown(() => debugPrint = previousDebugPrint);
    final launcher = DirectCoreLauncher(
      startProcess: (_, _) async => _FakeProcess(
        pid: 42,
        exitCode: Completer<int>().future,
        stderr: stderr.stream,
      ),
      corePath: 'FlClashCore',
    );

    await launcher.start(
      sessionId: '0123456789abcdef0123456789abcdef',
      address: 'test-address',
    );
    final bytes = utf8.encode('线路连接成功');
    stderr.add(bytes.sublist(0, 1));
    stderr.add(bytes.sublist(1));
    stderr.add([0xff]);
    await stderr.close();
    await pumpEventQueue();

    expect(logs.join(), contains('线路连接成功'));
    expect(logs.join(), contains('\uFFFD'));
  });

  test('createCoreSessionId returns lowercase 128-bit hex', () {
    expect(createCoreSessionId(), matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('direct lease kills and confirms the owned process exit', () async {
    final process = _FakeProcess(pid: 42, exitCode: Future.value(0));
    String? executable;
    List<String>? arguments;
    final launcher = DirectCoreLauncher(
      startProcess: (value, valueArguments) async {
        executable = value;
        arguments = valueArguments;
        return process;
      },
      corePath: 'FlClashCore',
    );

    final lease = await launcher.start(
      sessionId: '0123456789abcdef0123456789abcdef',
      address: 'test-address',
    );
    final result = await lease.stop(const Duration(seconds: 1));

    expect(lease.owner, CoreProcessOwner.direct);
    expect(lease.pid, 42);
    expect(executable, 'FlClashCore');
    expect(arguments, ['test-address']);
    expect(process.killed, isTrue);
    expect(
      result,
      const CoreProcessStopResult(stopped: true, exitConfirmed: true),
    );
  });

  test('direct lease reports an unconfirmed exit after timeout', () async {
    final process = _FakeProcess(pid: 42, exitCode: Completer<int>().future);
    final launcher = DirectCoreLauncher(
      startProcess: (_, _) async => process,
      corePath: 'FlClashCore',
    );
    final lease = await launcher.start(
      sessionId: '0123456789abcdef0123456789abcdef',
      address: 'test-address',
    );

    final result = await lease.stop(Duration.zero);

    expect(result.stopped, isTrue);
    expect(result.exitConfirmed, isFalse);
  });

  test('direct lease rechecks exit after an unconfirmed timeout', () async {
    final exitCode = Completer<int>();
    final process = _FakeProcess(pid: 42, exitCode: exitCode.future);
    final launcher = DirectCoreLauncher(
      startProcess: (_, _) async => process,
      corePath: 'FlClashCore',
    );
    final lease = await launcher.start(
      sessionId: '0123456789abcdef0123456789abcdef',
      address: 'test-address',
    );

    final firstResult = await lease.stop(Duration.zero);
    exitCode.complete(0);
    final secondResult = await lease.stop(const Duration(seconds: 1));

    expect(firstResult.exitConfirmed, isFalse);
    expect(secondResult.exitConfirmed, isTrue);
  });
}

class _FakeProcess implements Process {
  @override
  final int pid;

  @override
  final Future<int> exitCode;

  @override
  final Stream<List<int>> stdout = const Stream.empty();

  @override
  final Stream<List<int>> stderr;

  bool killed = false;

  _FakeProcess({
    required this.pid,
    required this.exitCode,
    this.stderr = const Stream.empty(),
  });

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}
