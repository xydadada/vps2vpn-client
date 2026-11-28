import 'dart:convert';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/desktop/rpc_client.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/core/spill.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop/fakes.dart';

class _RecordingCore extends CoreHandlerInterface {
  final calls = <CoreMethod, Object?>{};

  @override
  Future<Object?> invokeMethod({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
    CoreResultModel? model,
  }) async {
    calls[method] = arguments;
    return switch (method) {
      CoreMethod.configDecrypt => 'mode: rule',
      CoreMethod.proxyValidate => <Object?>[],
      CoreMethod.shareLinkDecode => <Object?>[<Object?>[]],
      _ => null,
    };
  }

  @override
  Future<CoreLifecycleResult> start() async => const CoreLifecycleResult(
    revision: 0,
    outcome: CoreLifecycleOutcome.applied,
  );

  @override
  Future<CoreLifecycleResult> restart() => start();

  @override
  Future<CoreLifecycleResult> stop() => start();

  @override
  Future<CoreLifecycleResult> close() => start();
}

void main() {
  late List<String> messages;

  setUp(() {
    messages = [];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) messages.add(message);
    };
    addTearDown(() => debugPrint = original);
  });

  test('Core calls retain credentials on the wire but not in logs', () async {
    final core = _RecordingCore();
    const key = 'REDACTED_AGE_KEY';
    const path = '/REDACTED/profile.yaml';
    const proxy = {'name': 'example', 'password': 'REDACTED_PASSWORD'};
    const share = 'vless://REDACTED@example.com:443';
    const provider = 'proxies:\n  - password: REDACTED_PROVIDER_PASSWORD';

    expect(await core.decryptConfig(path, key), 'mode: rule');
    expect(await core.validateProxies([proxy]), isEmpty);
    await core.decodeShareLinks([share]);
    await core.sideLoadExternalProvider(
      providerName: 'example',
      data: provider,
    );

    expect(core.calls[CoreMethod.configDecrypt], {
      'path': path,
      'age-secret-key': key,
    });
    expect(core.calls[CoreMethod.proxyValidate], {
      'proxies': [proxy],
    });
    expect(core.calls[CoreMethod.shareLinkDecode], {
      'lines': [share],
    });
    expect(core.calls[CoreMethod.providerSideLoad], {
      'name': 'example',
      'data': provider,
    });
    final output = messages.join('\n');
    expect(output, isNot(contains('REDACTED')));
    expect(output, isNot(contains('example.com')));
    if (watchExecution) {
      for (final method in core.calls.keys) {
        expect(output, contains('Invoke method ${method.wireName}'));
        expect(output, contains('${method.wireName} completed in'));
      }
    } else {
      expect(output, isEmpty);
    }
  });

  test(
    'malformed Core replies log the error class without the source',
    () async {
      final transport = FakeDesktopCoreTransport.connected();
      final client = CoreRpcClient(transport);
      try {
        transport.addFrame(
          Uint8List.fromList(utf8.encode('{"id":"REDACTED_RESPONSE",')),
        );
        await pumpEventQueue();
        final output = messages.join('\n');
        expect(output, contains('Failed to parse transport data'));
        expect(output, contains('FormatException'));
        expect(output, isNot(contains('REDACTED_RESPONSE')));

        final result = client.invoke(method: CoreMethod.coreInitialized);
        await pumpEventQueue();
        final request = jsonDecode(transport.sentMessages.single) as Map;
        transport.addJson({'id': request['id'], 'result': true});
        expect(await result, isTrue);
      } finally {
        await client.close();
        await transport.close();
      }
    },
  );

  for (final padding in [0, coreIsolateDecodeBytes]) {
    test('invalid callback values are private with $padding padding', () async {
      final transport = FakeDesktopCoreTransport.connected();
      final client = CoreRpcClient(transport);
      try {
        transport.addJson({
          'method': 'REDACTED_CALLBACK',
          'arguments': {'password': 'REDACTED_PASSWORD'},
          'padding': 'x' * padding,
        });
        for (var attempt = 0; attempt < 100 && messages.isEmpty; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final output = messages.join('\n');
        expect(output, contains('Failed to parse transport data'));
        expect(output, isNot(contains('REDACTED')));
        expect(output, contains('ArgumentError'));

        final result = client.invoke(method: CoreMethod.coreInitialized);
        await pumpEventQueue();
        final request = jsonDecode(transport.sentMessages.single) as Map;
        transport.addJson({'id': request['id'], 'result': true});
        expect(await result, isTrue);
      } finally {
        await client.close();
        await transport.close();
      }
    });
  }
}
