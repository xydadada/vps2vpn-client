import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/icon_file_service.dart';
import 'package:flutter_test/flutter_test.dart';

// A concrete HttpOverrides falls back to Dart's real socket client in tests.
class _RealHttpOverrides extends HttpOverrides {}

void main() {
  test(
    'accepts exactly the limit and does not trust a smaller declaration',
    () async {
      expect(
        await readIconBytes(
          Stream.fromIterable([
            [1, 2],
            [3, 4],
          ]),
          maxBytes: 4,
        ),
        [1, 2, 3, 4],
      );
      await expectLater(
        readIconBytes(
          Stream.fromIterable([
            [1, 2],
            [3, 4],
            [5],
          ]),
          declaredLength: 1,
          maxBytes: 4,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'declared oversized and stalled responses cancel their source',
    () async {
      for (final length in [5, null]) {
        var cancelled = false;
        final source = StreamController<List<int>>(
          onCancel: () => cancelled = true,
        );
        await expectLater(
          readIconBytes(
            source.stream,
            declaredLength: length,
            maxBytes: 4,
            timeout: const Duration(milliseconds: 20),
          ),
          length == null
              ? throwsA(isA<TimeoutException>())
              : throwsFormatException,
        );
        expect(cancelled, isTrue);
        await source.close();
      }
    },
  );

  test(
    'continued partial progress does not reset the total deadline',
    () async {
      var cancelled = false;
      Timer? timer;
      final source = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
          timer?.cancel();
        },
      );
      timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
        source.add([1]);
      });
      await expectLater(
        readIconBytes(
          source.stream,
          maxBytes: 1 << 20,
          timeout: const Duration(milliseconds: 30),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(cancelled, isTrue);
      await source.close();
    },
  );

  test('HTTP metadata and 304 survive the bounded download adapter', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => origin.close(force: true));
    origin.listen((request) async {
      if (request.uri.path == '/unchanged') {
        request.response.statusCode = HttpStatus.notModified;
      } else {
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'image/png',
        );
        request.response.headers.set(HttpHeaders.etagHeader, 'icon-v1');
        request.response.add([1, 2, 3]);
      }
      await request.response.close();
    });
    final service = IconFileService();
    final response = await HttpOverrides.runWithHttpOverrides(
      () => service.get('http://127.0.0.1:${origin.port}/icon'),
      _RealHttpOverrides(),
    );
    expect(response.statusCode, 200);
    expect(response.contentLength, 3);
    expect(response.eTag, 'icon-v1');
    expect(response.fileExtension, '.png');
    expect(await response.content.expand((bytes) => bytes).toList(), [1, 2, 3]);
    final unchanged = await HttpOverrides.runWithHttpOverrides(
      () => service.get('http://127.0.0.1:${origin.port}/unchanged'),
      _RealHttpOverrides(),
    );
    expect(unchanged.statusCode, 304);
    expect(await unchanged.content.expand((bytes) => bytes).toList(), isEmpty);
  });
}
