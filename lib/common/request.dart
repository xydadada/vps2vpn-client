import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' show join;

const maxSubscriptionBytes = 32 << 20;

class Request {
  late final Dio dio;

  @visibleForTesting
  late final Dio clashDio;

  @visibleForTesting
  late final Dio directDio;

  /// Refuses an untrusted certificate even with the certificate check turned
  /// off, because what it fetches is installed, on Windows as administrator.
  @visibleForTesting
  late final Dio releaseDio;
  String? userAgent;

  ProviderReader? _read;

  void attach(ProviderReader read) {
    _read = read;
  }

  static const _requestTimeout = Duration(seconds: 15);

  Request() {
    dio = Dio(
      BaseOptions(
        headers: {'User-Agent': browserUa},
        connectTimeout: _requestTimeout,
        receiveTimeout: _requestTimeout,
      ),
    );
    clashDio = _downloadDio(_findProxy);
    directDio = _downloadDio((_) => 'DIRECT');
    releaseDio = Dio(
      BaseOptions(
        headers: {'User-Agent': browserUa},
        connectTimeout: _requestTimeout,
        receiveTimeout: _requestTimeout,
      ),
    );
    releaseDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        return HttpClient()
          ..badCertificateCallback = ((_, _, _) => false)
          ..findProxy = _findProxy;
      },
    );
  }

  static Dio _downloadDio(String Function(Uri uri) findProxy) {
    return Dio()
      ..httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          client.findProxy = (Uri uri) {
            client.userAgent = globalState.ua;
            return findProxy(uri);
          };
          return client;
        },
      );
  }

  String _findProxy(Uri uri) {
    final read = _read;
    if (read == null) {
      return 'DIRECT';
    }
    return FlClashHttpOverrides.findProxyForReader(read, uri);
  }

  /// Counts bytes after HttpClient's gzip decoding, not by Content-Length.
  Future<Response<Uint8List>> _downloadCapped(
    String url,
    int maxBytes, {
    Dio? via,
  }) {
    final target = downloadTarget(url);
    final cancelToken = CancelToken();
    StreamSubscription<Uint8List>? body;

    Future<Response<Uint8List>> receive() async {
      try {
        final response = await (via ?? clashDio).getUri<ResponseBody>(
          target.uri,
          options: Options(
            responseType: ResponseType.stream,
            headers: target.headers,
          ),
          cancelToken: cancelToken,
        );
        final declared = int.tryParse(
          response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
        );
        if (declared != null && declared > maxBytes) {
          throw SubscriptionTooLargeException(maxBytes);
        }
        final bytes = BytesBuilder(copy: false);
        final done = Completer<void>();
        body = (response.data?.stream ?? const Stream<Uint8List>.empty())
            .listen(
              (chunk) {
                if (done.isCompleted) return;
                if (chunk.length > maxBytes - bytes.length) {
                  done.completeError(SubscriptionTooLargeException(maxBytes));
                  return;
                }
                bytes.add(chunk);
              },
              onError: (Object error, StackTrace stack) {
                if (!done.isCompleted) done.completeError(error, stack);
              },
              onDone: () {
                if (!done.isCompleted) done.complete();
              },
              cancelOnError: true,
            );
        await done.future;
        return Response<Uint8List>(
          data: bytes.takeBytes(),
          requestOptions: response.requestOptions,
          headers: response.headers,
          statusCode: response.statusCode,
          statusMessage: response.statusMessage,
          isRedirect: response.isRedirect,
          redirects: response.redirects,
          extra: response.extra,
        );
      } catch (_) {
        cancelToken.cancel();
        await body?.cancel();
        rethrow;
      }
    }

    return receive().timeout(
      downloadTimeoutDuration,
      onTimeout: () {
        cancelToken.cancel();
        unawaited(body?.cancel());
        throw DioException.receiveTimeout(
          timeout: downloadTimeoutDuration,
          requestOptions: RequestOptions(path: url),
        );
      },
    );
  }

  /// Bounded like a subscription: what it fetches (a custom config, a MITM
  /// resource) is held in memory whole.
  Future<Response<Uint8List>> getFileResponseForUrl(
    String url, {
    int maxBytes = maxSubscriptionBytes,
  }) async {
    try {
      return await _downloadCapped(url, maxBytes);
    } catch (e) {
      commonPrint.log(
        'getFileResponseForUrl error ${compactError(e)}',
        logLevel: LogLevel.warning,
      );
      rethrow;
    }
  }

  /// Retries directly when the proxy route fails, since the lines this
  /// update would replace may be the ones that died.
  Future<Response<Uint8List>> getSubscriptionResponse(
    String url, {
    int maxBytes = maxSubscriptionBytes,
  }) async {
    final proxied = _findProxy(downloadTarget(url).uri) != 'DIRECT';
    try {
      return await _downloadCapped(url, maxBytes);
    } catch (error) {
      if (!proxied || !isRouteFailure(error)) {
        commonPrint.log(
          'getSubscriptionResponse error ${compactError(error)}',
          logLevel: LogLevel.warning,
        );
        rethrow;
      }
      commonPrint.log(
        'getSubscriptionResponse via proxy failed, retrying directly: '
        '${compactError(error)}',
        logLevel: LogLevel.warning,
      );
    }
    try {
      return await _downloadCapped(url, maxBytes, via: directDio);
    } catch (error) {
      commonPrint.log(
        'getSubscriptionResponse direct retry error ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
      rethrow;
    }
  }

  /// Bounded too: a script, icon set or module is held in memory whole.
  Future<Response<String>> getTextResponseForUrl(
    String url, {
    int maxBytes = maxSubscriptionBytes,
  }) async {
    try {
      final response = await _downloadCapped(url, maxBytes);
      return Response<String>(
        data: utf8.decode(response.data!, allowMalformed: true),
        requestOptions: response.requestOptions,
        headers: response.headers,
        statusCode: response.statusCode,
        statusMessage: response.statusMessage,
        isRedirect: response.isRedirect,
        redirects: response.redirects,
        extra: response.extra,
      );
    } on SubscriptionTooLargeException {
      commonPrint.log(
        'getTextResponseForUrl error: over $maxBytes bytes',
        logLevel: LogLevel.warning,
      );
      throw DownloadTooLargeException(maxBytes);
    } catch (e) {
      commonPrint.log(
        'getTextResponseForUrl error ${compactError(e)}',
        logLevel: LogLevel.warning,
      );
      rethrow;
    }
  }

  /// Null when this build is current; throws when GitHub cannot be asked.
  Future<Map<String, dynamic>?> checkForUpdate() async {
    final release = await latestRelease();
    final remoteVersion = release['tag_name'] as String;
    final version = globalState.packageInfo.version;
    final hasUpdate =
        compareVersions(remoteVersion.replaceAll('v', ''), version) > 0;
    return hasUpdate ? release : null;
  }

  /// The release page redirect still answers once the hourly API quota is spent.
  Future<Map<String, dynamic>> latestRelease() async {
    try {
      final response = await releaseDio.get<Map<String, dynamic>>(
        'https://api.github.com/repos/$repository/releases/latest',
        options: Options(responseType: ResponseType.json),
      );
      return response.data!;
    } on DioException catch (error) {
      commonPrint.log(
        'latest release API failed: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
    }
    final response = await releaseDio.get<void>(
      'https://github.com/$repository/releases/latest',
      options: Options(
        followRedirects: false,
        validateStatus: (status) => status != null && status < 400,
      ),
    );
    final location = response.headers.value(HttpHeaders.locationHeader);
    final segments = Uri.tryParse(location ?? '')?.pathSegments ?? const [];
    final tagIndex = segments.indexOf('tag') + 1;
    if (tagIndex == 0 || tagIndex >= segments.length) {
      throw FormatException('No release tag in the redirect', location);
    }
    return {'tag_name': segments[tagIndex]};
  }

  Future<String> downloadVerifiedRelease({
    required String tag,
    required String name,
    required String directory,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    final sums = await releaseDio.getUri<String>(
      releaseAssetUri(tag, updateChecksumsName(tag)),
      options: Options(responseType: ResponseType.plain),
      cancelToken: cancelToken,
    );
    final expected = releaseChecksum(sums.data ?? '', name);
    if (expected == null) {
      throw ReleaseNotVerifiedException(name);
    }
    final path = join(directory, name);
    final uri = releaseAssetUri(tag, name);
    // Download into an unpredictable sibling rather than the final file:
    // both Dio and Android DownloadManager may truncate or delete their
    // destination before any network or checksum error is known.
    // Keep staging on the same filesystem for an atomic publish.
    final random = Random.secure();
    final suffix = [
      random.nextInt(1 << 32).toRadixString(36),
      random.nextInt(1 << 32).toRadixString(36),
    ].join();
    final staged = File(join(directory, '.vps2vpn-$suffix-$name'));
    try {
      if (app case final android?) {
        await android.downloadFile(
          uri,
          staged.path,
          title: name,
          onReceiveProgress: onReceiveProgress ?? (_, _) {},
          cancelToken: cancelToken ?? CancelToken(),
        );
      } else {
        await releaseDio.downloadUri(
          uri,
          staged.path,
          onReceiveProgress: onReceiveProgress,
          cancelToken: cancelToken,
        );
      }
      if (await fileSha256(staged.path) != expected) {
        throw ReleaseNotVerifiedException(name);
      }
      // The user may cancel while the asynchronous hash is still running.
      if (cancelToken?.cancelError case final error?) {
        throw error;
      }
      // Publish only verified bytes. If the destination is locked and cannot
      // be replaced, fail without deleting the old verified installer.
      await staged.rename(path);
      return path;
    } finally {
      await _deleteStaged(staged);
    }
  }
}

/// Removes a staging file unless a successful rename already did. A cancelled
/// Dio download fails its future before it has closed the file, and Windows
/// refuses to delete an open file, so retry for a moment; anything still left
/// is cleared with the update folder at the next start.
Future<void> _deleteStaged(File staged) async {
  for (var attempt = 0; ; attempt++) {
    try {
      await staged.delete();
      return;
    } on FileSystemException {
      if (attempt >= 20 || !await staged.exists()) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

final request = Request();

/// Some subscription servers send a gzip or zlib body without saying so in
/// Content-Encoding, which is the only signal dart:io decompresses on.
Uint8List decompressUnlabeled(
  Uint8List bytes, {
  int maxOutputBytes = maxSubscriptionBytes,
}) {
  final codec = switch (bytes) {
    [0x1f, 0x8b, ...] => gzip,
    [0x78, final flags, ...] when (0x78 << 8 | flags) % 31 == 0 => zlib,
    _ => null,
  };
  if (codec == null) {
    return bytes;
  }
  final output = BytesBuilder();
  final sink = codec.decoder.startChunkedConversion(
    _BoundedDecompressionSink(output, maxOutputBytes),
  );
  try {
    sink.add(bytes);
    sink.close();
    return output.takeBytes();
  } on FormatException {
    return bytes;
  }
}

class _BoundedDecompressionSink implements Sink<List<int>> {
  _BoundedDecompressionSink(this.output, this.limit);

  final BytesBuilder output;
  final int limit;

  @override
  void add(List<int> chunk) {
    if (chunk.length > limit - output.length) {
      throw SubscriptionTooLargeException(limit);
    }
    output.add(chunk);
  }

  @override
  void close() {}
}

/// A 4xx is the server's verdict on the link, except 407 and 408, which come
/// from the route.
@visibleForTesting
bool isRouteFailure(Object error) {
  return switch (error) {
    DioException(type: DioExceptionType.cancel) => false,
    DioException(type: DioExceptionType.badResponse, :final response) =>
      switch (response?.statusCode) {
        HttpStatus.proxyAuthenticationRequired ||
        HttpStatus.requestTimeout ||
        null => true,
        final code => code >= HttpStatus.internalServerError,
      },
    DioException() ||
    SocketException() ||
    HttpException() ||
    TlsException() ||
    TimeoutException() => true,
    _ => false,
  };
}

/// dart:io turns [Uri.userInfo] into Basic credentials still percent-encoded.
@visibleForTesting
({Uri uri, Map<String, Object> headers}) downloadTarget(String url) {
  final uri = url.webUri ?? Uri.parse(url);
  if (uri.userInfo.isEmpty) {
    return (uri: uri, headers: const {});
  }
  final credentials = uri.userInfo.split(':').map(_decodeUserInfo).join(':');
  return (
    uri: uri.replace(userInfo: ''),
    headers: {
      HttpHeaders.authorizationHeader:
          'Basic ${base64.encode(utf8.encode(credentials))}',
    },
  );
}

String _decodeUserInfo(String value) {
  try {
    return Uri.decodeComponent(value);
  } on ArgumentError {
    return value;
  }
}

String? getFileNameForDisposition(String? disposition) {
  if (disposition == null) return null;
  try {
    final parseValue = HeaderValue.parse(disposition);
    final parameters = parseValue.parameters;
    final fileNamePointKey = parameters.keys.firstWhere(
      (key) => key == 'filename*',
      orElse: () => '',
    );
    if (fileNamePointKey.isNotEmpty) {
      final res = parameters[fileNamePointKey]?.split("''") ?? [];
      if (res.length >= 2) {
        return Uri.decodeComponent(res[1]);
      }
    }
    final fileNameKey = parameters.keys.firstWhere(
      (key) => key == 'filename',
      orElse: () => '',
    );
    if (fileNameKey.isEmpty) return null;
    return parameters[fileNameKey];
  } catch (_) {
    return null;
  }
}
