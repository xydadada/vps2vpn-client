import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/app_update.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/exception.dart';
import 'package:fl_clash/common/release_asset.dart';
import 'package:fl_clash/common/request.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

class _StalledHttpClient extends Fake implements HttpClient {
  @override
  Duration? connectionTimeout;

  @override
  String Function(Uri url)? findProxy;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      Completer<HttpClientRequest>().future;
}

class _HostAdapter implements HttpClientAdapter {
  _HostAdapter(this.byHost);

  final Map<String, ResponseBody Function()> byHost;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return byHost[options.uri.host]!();
  }

  @override
  void close({bool force = false}) {}
}

class _PathAdapter implements HttpClientAdapter {
  _PathAdapter(this.byPath);

  final Map<String, ResponseBody Function()> byPath;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return byPath[options.uri.path]!();
  }

  @override
  void close({bool force = false}) {}
}

class _CountingAdapter implements HttpClientAdapter {
  _CountingAdapter(this.answer);

  final ResponseBody Function(RequestOptions options) answer;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return answer(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody Function(RequestOptions) _unreachable(Exception error) {
  return (_) => throw error;
}

ResponseBody Function(RequestOptions) _status(int code, [String body = '']) {
  return (_) => ResponseBody.fromString(body, code);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('getTextResponseForUrl propagates the typed DioException', () async {
    // flutter_test's mocked HttpClient answers every request with HTTP 400,
    // which Dio surfaces as a badResponse DioException.
    await expectLater(
      request.getTextResponseForUrl('http://127.0.0.1/anything'),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.badResponse,
        ),
      ),
    );
  });

  test('getFileResponseForUrl propagates the typed DioException', () async {
    await expectLater(
      request.getFileResponseForUrl('http://127.0.0.1/anything'),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.badResponse,
        ),
      ),
    );
  });

  group('latestRelease', () {
    Request requestAnswering(Map<String, ResponseBody Function()> byHost) {
      return Request()..releaseDio.httpClientAdapter = _HostAdapter(byHost);
    }

    test('reads the release from the API', () async {
      final request = requestAnswering({
        'api.github.com': () => ResponseBody.fromString(
          '{"tag_name":"v1.2.3","body":"notes"}',
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      });

      expect(await request.latestRelease(), {
        'tag_name': 'v1.2.3',
        'body': 'notes',
      });
    });

    test(
      'falls back to the release page when the API is rate limited',
      () async {
        final request = requestAnswering({
          'api.github.com': () => ResponseBody.fromString('{}', 403),
          'github.com': () => ResponseBody.fromString(
            '',
            302,
            headers: {
              HttpHeaders.locationHeader: [
                'https://github.com/owner/repo/releases/tag/v1.2.4',
              ],
            },
          ),
        });

        expect(await request.latestRelease(), {'tag_name': 'v1.2.4'});
      },
    );

    test('fails instead of answering when neither endpoint does', () async {
      final request = requestAnswering({
        'api.github.com': () => ResponseBody.fromString('{}', 403),
        'github.com': () => ResponseBody.fromString('', 503),
      });

      await expectLater(request.latestRelease(), throwsA(isA<DioException>()));
    });
  });

  group('downloadVerifiedRelease', () {
    final name = releaseAssetName(
      line: appReleaseLine,
      version: '1.2.3',
      os: ReleaseOs.android,
      arch: ReleaseArch.arm64,
      extension: 'apk',
    );
    final package = utf8.encode('package');
    final digest = sha256.convert(package).toString();
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('release');
    });

    tearDown(() => directory.delete(recursive: true));

    Request requestServing(String sums, List<int> asset) {
      return Request()
        ..releaseDio.httpClientAdapter = _PathAdapter({
          '/$repository/releases/download/v1.2.3/${updateChecksumsName('v1.2.3')}':
              () => ResponseBody.fromString(sums, 200),
          '/$repository/releases/download/v1.2.3/$name': () =>
              ResponseBody.fromBytes(asset, 200),
        });
    }

    Future<String> download(Request request) {
      return request.downloadVerifiedRelease(
        tag: 'v1.2.3',
        name: name,
        directory: directory.path,
      );
    }

    test('keeps a file matching the published digest', () async {
      final request = requestServing('$digest  ./$name\n', package);

      final path = await download(request);

      expect(await File(path).readAsBytes(), package);
    });

    test('refuses a file that does not match', () async {
      final request = requestServing('$digest  ./$name\n', utf8.encode('x'));

      await expectLater(
        download(request),
        throwsA(isA<ReleaseNotVerifiedException>()),
      );
    });

    test('refuses an asset the listing does not name', () async {
      final request = requestServing('$digest  ./other.apk\n', package);

      await expectLater(
        download(request),
        throwsA(isA<ReleaseNotVerifiedException>()),
      );
      expect(directory.listSync(), isEmpty);
    });
  });

  group('getSubscriptionResponse', () {
    const url = 'https://sub.example.com/token';

    ({Request request, _CountingAdapter proxied, _CountingAdapter direct})
    routes({
      required ResponseBody Function(RequestOptions) proxied,
      required ResponseBody Function(RequestOptions) direct,
      bool running = true,
    }) {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(runTimeProvider.notifier).value = running ? 1 : null;
      final proxiedAdapter = _CountingAdapter(proxied);
      final directAdapter = _CountingAdapter(direct);
      final request = Request()
        ..attach(container.read)
        ..clashDio.httpClientAdapter = proxiedAdapter
        ..directDio.httpClientAdapter = directAdapter;
      return (request: request, proxied: proxiedAdapter, direct: directAdapter);
    }

    test('fetches directly once the proxied route fails', () async {
      final (:request, :proxied, :direct) = routes(
        proxied: _unreachable(const SocketException('Connection refused')),
        direct: _status(200, 'proxies: []'),
      );

      final response = await request.getSubscriptionResponse(url);

      expect(utf8.decode(response.data!), 'proxies: []');
      expect((proxied.calls, direct.calls), (1, 1));
    });

    test('fetches directly when the proxy answers for a dead line', () async {
      final (:request, :proxied, :direct) = routes(
        proxied: _status(502),
        direct: _status(200, 'proxies: []'),
      );

      await request.getSubscriptionResponse(url);

      expect((proxied.calls, direct.calls), (1, 1));
    });

    for (final code in [401, 403, 404]) {
      test('takes a $code as the verdict on the link', () async {
        final (:request, :proxied, :direct) = routes(
          proxied: _status(code),
          direct: _status(200),
        );

        await expectLater(
          request.getSubscriptionResponse(url),
          throwsA(
            isA<DioException>().having(
              (e) => e.response?.statusCode,
              'status',
              code,
            ),
          ),
        );
        expect((proxied.calls, direct.calls), (1, 0));
      });
    }

    test('does not retry a direct fetch made while the proxy is off', () async {
      final (:request, :proxied, :direct) = routes(
        running: false,
        proxied: _unreachable(const SocketException('Network is unreachable')),
        direct: _status(200),
      );

      await expectLater(
        request.getSubscriptionResponse(url),
        throwsA(isA<DioException>()),
      );
      expect((proxied.calls, direct.calls), (1, 0));
    });

    test('fails with the direct error when both routes fail', () async {
      final (:request, :proxied, :direct) = routes(
        proxied: _unreachable(const SocketException('Connection refused')),
        direct: _unreachable(const SocketException('Connection reset')),
      );

      await expectLater(
        request.getSubscriptionResponse(url),
        throwsA(
          isA<DioException>().having(
            (e) => (e.error as SocketException).message,
            'error',
            'Connection reset',
          ),
        ),
      );
      expect((proxied.calls, direct.calls), (1, 1));
    });
  });

  group('isRouteFailure', () {
    final options = RequestOptions(path: 'https://sub.example.com');
    DioException answered(int code) => DioException.badResponse(
      statusCode: code,
      requestOptions: options,
      response: Response(requestOptions: options, statusCode: code),
    );

    test('counts failures on the way', () {
      expect(isRouteFailure(const SocketException('refused')), isTrue);
      expect(isRouteFailure(TimeoutException('slow')), isTrue);
      expect(
        isRouteFailure(
          DioException.receiveTimeout(
            timeout: downloadTimeoutDuration,
            requestOptions: options,
          ),
        ),
        isTrue,
      );
      expect(
        isRouteFailure(
          DioException.connectionError(
            requestOptions: options,
            reason: 'reset',
          ),
        ),
        isTrue,
      );
      for (final code in [407, 408, 500, 502, 503, 504]) {
        expect(isRouteFailure(answered(code)), isTrue, reason: '$code');
      }
    });

    test('leaves answers, cancels and invalid bodies alone', () {
      for (final code in [400, 401, 403, 404, 410, 429]) {
        expect(isRouteFailure(answered(code)), isFalse, reason: '$code');
      }
      expect(
        isRouteFailure(
          DioException.requestCancelled(
            requestOptions: options,
            reason: 'cancelled',
          ),
        ),
        isFalse,
      );
      expect(isRouteFailure(const MessageException('invalid')), isFalse);
      expect(isRouteFailure(const FormatException('yaml')), isFalse);
    });
  });

  group('downloadTarget', () {
    test('sends a URL without credentials unchanged', () {
      final target = downloadTarget('https://example.com/a.yaml?x=1');

      expect(target.uri.toString(), 'https://example.com/a.yaml?x=1');
      expect(target.headers, isEmpty);
    });

    test('moves decoded credentials into the Authorization header', () {
      for (final url in [
        'https://me@mail.com:p:w@dav.example.com/dav/a.yaml',
        'https://me%40mail.com:p%3Aw@dav.example.com/dav/a.yaml',
      ]) {
        final target = downloadTarget(url);

        expect(target.uri.toString(), 'https://dav.example.com/dav/a.yaml');
        expect(
          target.headers[HttpHeaders.authorizationHeader],
          'Basic ${base64.encode(utf8.encode('me@mail.com:p:w'))}',
        );
      }
    });
  });

  group('decompressUnlabeled', () {
    final yaml = utf8.encode('proxies: []\n');

    test('inflates a gzip or zlib body that arrived unlabeled', () {
      for (final codec in [gzip, zlib]) {
        final body = Uint8List.fromList(codec.encode(yaml));

        expect(decompressUnlabeled(body), yaml);
      }
    });

    test('rejects gzip and zlib bodies that inflate past the byte limit', () {
      for (final codec in [gzip, zlib]) {
        final compressed = Uint8List.fromList(
          codec.encode(List<int>.filled(2048, 65)),
        );

        expect(
          () => decompressUnlabeled(compressed, maxOutputBytes: 128),
          throwsA(isA<MessageException>()),
        );
      }
    });

    test('accepts decoded bodies at the exact byte limit', () {
      for (final codec in [gzip, zlib]) {
        final compressed = Uint8List.fromList(codec.encode(yaml));

        expect(
          decompressUnlabeled(compressed, maxOutputBytes: yaml.length),
          yaml,
        );
      }
    });

    test('leaves a plain body untouched', () {
      final body = Uint8List.fromList(yaml);

      expect(decompressUnlabeled(body), same(body));
    });

    test('keeps a body that only starts like gzip', () {
      final body = Uint8List.fromList([0x1f, 0x8b, 1, 2, 3]);

      expect(decompressUnlabeled(body), same(body));
    });
  });

  testWidgets('a stalled download fails at the shared download deadline', (
    tester,
  ) async {
    late final Future<Response<String>> pending;
    HttpOverrides.runZoned(() {
      pending = Request().getTextResponseForUrl('http://127.0.0.1/stalled');
    }, createHttpClient: (_) => _StalledHttpClient());
    var settled = false;
    final outcome = expectLater(
      pending.whenComplete(() => settled = true),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      ),
    );

    await tester.pump(downloadTimeoutDuration - const Duration(seconds: 1));
    expect(settled, isFalse);
    await tester.pump(const Duration(seconds: 1));
    await outcome;
  });
}
