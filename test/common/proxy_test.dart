import 'dart:async';

import 'package:fl_clash/common/proxy.dart';
import 'package:fl_clash/models/models.dart' show ProxyState;
import 'package:flutter_test/flutter_test.dart';

class _FakeProxy implements SystemProxy {
  final List<String> calls = [];
  Future<bool>? held;
  Error? failure;

  Future<bool> _call(String name) async {
    calls.add(name);
    final error = failure;
    failure = null;
    if (error != null) {
      throw error;
    }
    final result = held ?? Future.value(true);
    held = null;
    return result;
  }

  @override
  Future<bool> start(int port, List<String> bypassDomain, String? pacScript) {
    return _call('start $port');
  }

  @override
  Future<bool> stop() => _call('stop');
}

ProxyState _state({required bool isStart}) {
  return ProxyState(
    isStart: isStart,
    systemProxy: true,
    bassDomain: const [],
    port: 7890,
  );
}

void main() {
  test('the port to be replaced is noted before our proxy goes on', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);
    addTearDown(() => vpsBeforeSystemProxy = null);
    vpsBeforeSystemProxy = (port) async {
      proxy.calls.add('note $port');
      throw StateError('a failing note does not stop the proxy');
    };

    await queue.apply(_state(isStart: true));

    expect(proxy.calls, ['note 7890', 'start 7890']);
  });

  test('applies changes in the order they come', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);

    unawaited(queue.apply(_state(isStart: true)));
    await queue.apply(_state(isStart: false));

    expect(proxy.calls, ['start 7890', 'stop']);
  });

  test('close stops last and drops the starts queued before it', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);
    final inFlight = Completer<bool>();
    proxy.held = inFlight.future;

    unawaited(queue.apply(_state(isStart: true)));
    await pumpEventQueue();
    unawaited(queue.apply(_state(isStart: true)));
    final closed = queue.close();
    await pumpEventQueue();
    expect(proxy.calls, ['start 7890']);

    inFlight.complete(true);
    await closed;
    await queue.apply(_state(isStart: true));

    expect(proxy.calls, ['start 7890', 'stop']);
  });

  test('a failing call does not stall the queue', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);
    proxy.failure = StateError('channel gone');

    await queue.apply(_state(isStart: true));
    await queue.apply(_state(isStart: false));

    expect(proxy.calls, ['start 7890', 'stop']);
  });

  test('leaves a proxy it never set alone', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);

    await queue.apply(_state(isStart: false));
    await queue.close();

    expect(proxy.calls, isEmpty);
  });

  test('clears a start that reported failure, which may have written '
      'part of the settings', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);
    proxy.held = Future.value(false);

    await queue.apply(_state(isStart: true));
    await queue.close();

    expect(proxy.calls, ['start 7890', 'stop']);
  });

  test('copies a terminal proxy command each shell accepts', () {
    expect(
      proxyEnvCommand(7890, isWindows: true),
      r'$env:all_proxy="http://127.0.0.1:7890"',
    );
    expect(
      proxyEnvCommand(7890, isWindows: false),
      'export all_proxy=http://127.0.0.1:7890',
    );
  });

  test('tries a failed stop again on close', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);

    await queue.apply(_state(isStart: true));
    proxy.held = Future.value(false);
    await queue.apply(_state(isStart: false));
    await queue.close();
    await queue.close();

    expect(proxy.calls, ['start 7890', 'stop', 'stop']);
  });

  test('a delayed refresh cannot revive a newer stop', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);
    final inFlight = Completer<bool>();
    proxy.held = inFlight.future;
    unawaited(queue.apply(_state(isStart: true)));
    await pumpEventQueue();
    final refresh = queue.refresh(isCurrent: () => true);
    final stopped = queue.apply(_state(isStart: false));
    inFlight.complete(true);
    await Future.wait([refresh, stopped]);
    expect(proxy.calls, ['start 7890', 'stop']);
  });

  test('refresh checks authorization when its turn arrives', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);
    final inFlight = Completer<bool>();
    proxy.held = inFlight.future;
    unawaited(queue.apply(_state(isStart: true)));
    await pumpEventQueue();
    var allowed = true;
    final refresh = queue.refresh(isCurrent: () => allowed);
    allowed = false;
    inFlight.complete(true);
    await refresh;
    expect(proxy.calls, ['start 7890']);
  });

  test('refresh cannot start a closed or never configured queue', () async {
    final proxy = _FakeProxy();
    final queue = SystemProxyQueue(proxy);
    await queue.refresh(isCurrent: () => true);
    await queue.apply(_state(isStart: true));
    await queue.close();
    await queue.refresh(isCurrent: () => true);
    expect(proxy.calls, ['start 7890', 'stop']);
  });
}
