import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/request.dart';
import 'package:flutter_test/flutter_test.dart';

class _DownloadAdapter implements HttpClientAdapter {
  _DownloadAdapter(this.body);

  final ResponseBody Function() body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => body();

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Request serving(ResponseBody Function() body) {
    final request = Request()
      ..downloadDio.httpClientAdapter = _DownloadAdapter(body);
    addTearDown(() => request.downloadDio.close(force: true));
    return request;
  }

  test('a bounded download accepts its exact byte limit and metadata', () async {
    final request = serving(
      () => ResponseBody.fromBytes(
        [1, 2, 3, 4],
        200,
        headers: {
          'content-length': ['4'],
          'content-disposition': ['attachment; filename="resource.js"'],
        },
      ),
    );

    final response = await request.getFileResponseForUrl(
      'https://example.invalid/resource',
      maxBytes: 4,
    );

    expect(response.data, [1, 2, 3, 4]);
    expect(response.statusCode, 200);
    expect(response.headers.value('content-disposition'), contains('resource.js'));
  });

  test('a chunked oversized body is canceled before it is returned', () async {
    var closed = false;
    final request = serving(
      () => ResponseBody(
        Stream<Uint8List>.fromIterable([
          Uint8List.fromList([1, 2, 3]),
          Uint8List.fromList([4, 5, 6]),
        ]),
        200,
        onClose: () => closed = true,
      ),
    );

    await expectLater(
      request.getFileResponseForUrl(
        'https://example.invalid/chunked',
        maxBytes: 4,
      ),
      throwsA(isA<FileSystemException>()),
    );
    await pumpEventQueue();
    expect(closed, isTrue);
  });

  test('an oversized declared length is rejected without collecting it', () async {
    var closed = false;
    final request = serving(
      () => ResponseBody.fromBytes(
        [1],
        200,
        headers: {
          'content-length': ['1000000'],
        },
        onClose: () => closed = true,
      ),
    );

    await expectLater(
      request.getFileResponseForUrl(
        'https://example.invalid/declared',
        maxBytes: 4,
      ),
      throwsA(isA<FileSystemException>()),
    );
    await pumpEventQueue();
    expect(closed, isTrue);
  });

  testWidgets('the byte limit keeps the deadline through a stalled body', (
    tester,
  ) async {
    final body = StreamController<Uint8List>();
    var closed = false;
    final request = serving(
      () => ResponseBody(body.stream, 200, onClose: () => closed = true),
    );
    final outcome = expectLater(
      request.getFileResponseForUrl(
        'https://example.invalid/stalled',
        maxBytes: 4,
      ),
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      ),
    );
    await tester.pump();
    body.add(Uint8List.fromList([1]));
    await tester.pump(downloadTimeoutDuration);
    await outcome;
    await tester.pump();
    expect(closed, isTrue);
    await body.close();
  });
}
