import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/ip_quality.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter_test/flutter_test.dart';

const _ip = '203.0.113.9';
const _limit = 1 << 20;

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);

  final ResponseBody Function(RequestOptions) reply;
  final cancelled = <String>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    cancelFuture?.then((_) => cancelled.add(options.uri.host));
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _unavailable() => ResponseBody.fromString('', 503);

ResponseBody _fallback() => ResponseBody.fromString(
  '{"status":"success","hosting":false,"mobile":false}',
  200,
);

ResponseBody _laterAnswer() =>
    ResponseBody.fromString('{"company":{"type":"hosting"}}', 200);

Uint8List _document(int length) {
  final prefix = utf8.encode('{"ip":"$_ip","type":"isp","padding":"');
  final suffix = utf8.encode('"}');
  final bytes = Uint8List(length)..fillRange(0, length, 0x78);
  bytes.setRange(0, prefix.length, prefix);
  bytes.setRange(length - suffix.length, length, suffix);
  return bytes;
}

ResponseBody _chunks(Uint8List bytes) => ResponseBody(
  Stream<Uint8List>.fromIterable([
    for (var offset = 0; offset < bytes.length; offset += 16384)
      Uint8List.sublistView(
        bytes,
        offset,
        (offset + 16384).clamp(0, bytes.length),
      ),
  ]),
  200,
);

void main() {
  test(
    'a chunked oversized metadata document cannot win the source race',
    () async {
      final adapter = _Adapter(
        (options) => switch (options.uri.host) {
          'ident.me' => _chunks(_document(_limit + 1)),
          'iplocate.io' => _laterAnswer(),
          _ => _unavailable(),
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);

      final result = await lookupIpQuality(
        dio,
        _ip,
        cancelToken: CancelToken(),
      );
      await pumpEventQueue();

      expect(result.source, IpQualitySource.ipLocate);
      expect(adapter.cancelled, contains('ident.me'));
    },
  );

  test(
    'an oversized Content-Length is rejected even with a short body',
    () async {
      final adapter = _Adapter(
        (options) => switch (options.uri.host) {
          'ident.me' => ResponseBody.fromString(
            '{"ip":"$_ip","type":"isp"}',
            200,
            headers: {
              Headers.contentLengthHeader: ['${_limit + 1}'],
            },
          ),
          'iplocate.io' => _laterAnswer(),
          _ => _unavailable(),
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);

      final result = await lookupIpQuality(
        dio,
        _ip,
        cancelToken: CancelToken(),
      );

      expect(result.source, IpQualitySource.ipLocate);
    },
  );

  test('metadata exactly at the body limit is still accepted', () async {
    final adapter = _Adapter(
      (options) => options.uri.host == 'ident.me'
          ? _chunks(_document(_limit))
          : _unavailable(),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);

    final result = await lookupIpQuality(dio, _ip, cancelToken: CancelToken());

    expect(result.source, IpQualitySource.identMe);
    expect(result.type, IpType.residential);
  });

  test('body timeouts close every request and report timeout status', () async {
    final streams = <StreamController<Uint8List>>[];
    final closed = <String>{};
    final adapter = _Adapter((options) {
      final stream = StreamController<Uint8List>();
      streams.add(stream);
      return ResponseBody(
        stream.stream,
        200,
        onClose: () => closed.add(options.uri.host),
      );
    });
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    addTearDown(() async {
      for (final stream in streams) {
        await stream.close();
      }
    });
    final token = CancelToken();

    await expectLater(
      lookupIpQuality(
        dio,
        _ip,
        cancelToken: token,
        timeout: const Duration(milliseconds: 50),
        hedge: const Duration(milliseconds: 5),
      ),
      throwsA(
        isA<IpQualityLookupException>()
            .having(
              (error) => error.failures.map((item) => item.status),
              'source statuses',
              everyElement(IpQualitySourceStatus.timeout),
            )
            .having((error) => error.failures.length, 'source count', 6),
      ),
    );
    await pumpEventQueue();

    expect(token.isCancelled, isTrue);
    expect(closed, hasLength(6));
    expect(adapter.cancelled, hasLength(6));
  });

  test('an inferred fallback also releases the timed-out source', () async {
    final pending = StreamController<Uint8List>();
    var closed = false;
    final adapter = _Adapter(
      (options) => switch (options.uri.host) {
        'ident.me' => ResponseBody(
          pending.stream,
          200,
          onClose: () => closed = true,
        ),
        'ip-api.com' => _fallback(),
        _ => _unavailable(),
      },
    );
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    addTearDown(pending.close);
    final token = CancelToken();

    final result = await lookupIpQuality(
      dio,
      _ip,
      cancelToken: token,
      timeout: const Duration(milliseconds: 50),
      hedge: const Duration(milliseconds: 5),
    );
    await pumpEventQueue();

    expect(result.source, IpQualitySource.ipApiCom);
    expect(result.type, IpType.residential);
    expect(closed, isTrue);
    expect(token.isCancelled, isTrue);
    expect(adapter.cancelled, contains('ident.me'));
  });
}
