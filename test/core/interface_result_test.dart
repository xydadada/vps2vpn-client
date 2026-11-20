import 'dart:io';

import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/core/spill.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

class _NullCore extends CoreHandlerInterface {
  final invoked = <CoreMethod>[];

  @override
  Future<Object?> invokeMethod({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
    CoreResultModel? model,
  }) async {
    invoked.add(method);
    return null;
  }

  @override
  Future<CoreLifecycleResult> start() async => _unused;

  @override
  Future<CoreLifecycleResult> restart() async => _unused;

  @override
  Future<CoreLifecycleResult> stop() async => _unused;

  @override
  Future<CoreLifecycleResult> close() async => _unused;
}

const _unused = CoreLifecycleResult(
  revision: 0,
  outcome: CoreLifecycleOutcome.applied,
);

const _setupParams = SetupParams(
  selectedMap: {},
  options: CoreOptions(testUrl: 'http://x.com'),
);

const _updateParams = UpdateParams(
  tun: Tun(),
  mixedPort: 7890,
  allowLan: true,
  findProcessMode: FindProcessMode.strict,
  mode: Mode.rule,
  logLevel: LogLevel.info,
  ipv6: false,
  tcpConcurrent: false,
  externalController: ExternalControllerStatus.close,
  unifiedDelay: false,
  options: CoreOptions(testUrl: 'http://x.com'),
);

final _emptyResult = throwsA(
  isA<CoreMethodException>().having(
    (error) => error.code,
    'code',
    'empty_result',
  ),
);

void main() {
  late _NullCore core;

  setUp(() => core = _NullCore());

  test('a command succeeds on an answer that carries nothing', () async {
    await core.setupConfig(_setupParams);
    await core.updateConfig(_updateParams);
    await core.updateGeoData('GeoIp');
    await core.updateExternalProvider('provider');
    await core.sideLoadExternalProvider(providerName: 'p', data: 'd');
    await core.clearEffect(1);
    await core.forceGc();
    await core.startListener();
    await core.stopListener();

    expect(core.invoked, hasLength(9));
  });

  final queries = <String, Future<Object?> Function()>{
    'isInit': () => core.isInit,
    'getMemoryStats': () => core.getMemoryStats(),
    'changeProxy': () => core.changeProxy(
      const ChangeProxyParams(groupName: 'G', proxyName: 'P'),
    ),
    'getExternalProviders': () => core.getExternalProviders(),
    'watchRoute': () => core.watchRoute(true),
    'validateProxies': () => core.validateProxies(const [{}]),
    'getTraffic': () => core.getTraffic(false),
  };

  group('a query that answers nothing fails instead of defaulting', () {
    queries.forEach((name, invoke) {
      test(name, () => expect(invoke(), _emptyResult));
    });
  });

  test('a lookup reads nothing as nothing found', () async {
    expect(await core.validateConfig('/tmp/config.yaml'), isNull);
    expect(await core.getExternalProvider('p'), isNull);
    expect(await core.getProxyDefinition('p'), isNull);
    expect(await core.getMitmCertificate(), isNull);
  });

  test(
    'decrypt does not invoke the Core when the app cannot read a file',
    () async {
      final home = await Directory.systemTemp.createTemp('decrypt-missing-');
      addTearDown(() => home.delete(recursive: true));
      await expectLater(
        core.decryptConfig('${home.path}/missing.age', 'AGE-SECRET-KEY-1A'),
        throwsA(isA<FileSystemException>()),
      );
      expect(core.invoked, isEmpty);
    },
  );

  test(
    'decrypt rejects an oversized ordinary file before invoking the Core',
    () async {
      final home = await Directory.systemTemp.createTemp('decrypt-large-');
      addTearDown(() => home.delete(recursive: true));
      final file = File('${home.path}/large.age');
      final output = await file.open(mode: FileMode.write);
      try {
        await output.truncate(64 << 20);
      } finally {
        await output.close();
      }

      await expectLater(
        core.decryptConfig(file.path, 'AGE-SECRET-KEY-1A'),
        throwsA(
          isA<CoreMethodException>().having(
            (error) => error.code,
            'code',
            'request_too_large',
          ),
        ),
      );
      expect(core.invoked, isEmpty);
    },
  );

  test(
    'decrypt still requires a result after reading a valid local file',
    () async {
      final home = await Directory.systemTemp.createTemp('decrypt-result-');
      addTearDown(() => home.delete(recursive: true));
      final file = File('${home.path}/profile.age');
      await file.writeAsBytes([0, 128, 255]);

      await expectLater(
        core.decryptConfig(file.path, 'AGE-SECRET-KEY-1A'),
        _emptyResult,
      );
      expect(core.invoked, [CoreMethod.configDecrypt]);
    },
  );

  test('calls nobody waits on absorb a Core that is gone', () async {
    final core = _DisconnectedCore();

    await core.resetTraffic();
    await core.startLog();
    await core.stopLog();

    expect(core.invoked, [
      CoreMethod.trafficReset,
      CoreMethod.logStart,
      CoreMethod.logStop,
    ]);
  });

  test('a command the Core refuses surfaces its error', () async {
    final core = _DisconnectedCore();

    await expectLater(
      core.setupConfig(_setupParams),
      throwsA(isA<CoreMethodException>()),
    );
  });
}

class _DisconnectedCore extends _NullCore {
  @override
  Future<Object?> invokeMethod({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
    CoreResultModel? model,
  }) async {
    invoked.add(method);
    throw const CoreMethodException(
      code: 'transport_disconnected',
      message: 'Core RPC client is closed',
    );
  }
}
