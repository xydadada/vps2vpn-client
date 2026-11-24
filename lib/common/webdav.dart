import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/string.dart';

final class DAVException implements Exception {
  final String method;
  final String path;
  final int? statusCode;
  final String? reasonPhrase;

  const DAVException({
    required this.method,
    required this.path,
    this.statusCode,
    this.reasonPhrase,
  });

  @override
  String toString() {
    final reason = reasonPhrase?.trim();
    final detail = [
      if (statusCode != null) '$statusCode',
      if (reason != null && reason.isNotEmpty) reason,
    ].join(' ');
    return 'WebDAV $method $path failed: ${detail.isEmpty ? 'no response' : detail}';
  }
}

/// Requests go through `Dio`, so they inherit the app-wide HttpOverrides: the
/// user's proxy selection and the TLS certificate setting apply here too.
class DAVTransport {
  DAVTransport({
    required String uri,
    required this.user,
    required this.password,
    Dio? dio,
  }) : _base = Uri.tryParse(uri.trim()),
       _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout = const Duration(seconds: 8)
      ..sendTimeout = const Duration(seconds: 60)
      ..receiveTimeout = const Duration(seconds: 60);
  }

  static const _maxRedirects = 5;
  static const maxBackupBytes = 512 * 1024 * 1024;

  final String user;
  final String password;
  final Uri? _base;
  final Dio _dio;

  _DigestChallenge? _digest;
  int _digestNonceCount = 0;

  Uri resolve(String path, {bool collection = false}) {
    final base = _base;
    if (base == null ||
        (base.scheme != 'http' && base.scheme != 'https') ||
        base.host.isEmpty) {
      throw const FormatException('Invalid WebDAV URI');
    }
    if (path.contains('\\')) {
      throw ArgumentError.value(path, 'path', 'Backslash is not allowed');
    }
    final baseSegments = base.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    final pathSegments = path
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (baseSegments.any((segment) => segment == '..') ||
        pathSegments.any((segment) => segment == '..' || segment == '.')) {
      throw ArgumentError.value(path, 'path', 'Path traversal is not allowed');
    }
    final segments = [...baseSegments, ...pathSegments];
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      pathSegments: collection ? [...segments, ''] : segments,
    );
  }

  Future<void> options(String path) async {
    await _send('OPTIONS', path, collection: true, accept: const {200, 204});
  }

  /// 405 means the collection is already there, which is the common case: the
  /// backup directory only has to be created once per account.
  Future<void> mkcol(String path) async {
    await _send(
      'MKCOL',
      path,
      collection: true,
      accept: const {200, 201, 204, 405},
    );
  }

  Future<void> put(String path, List<int> bytes) async {
    await _send(
      'PUT',
      path,
      body: bytes,
      headers: {
        Headers.contentTypeHeader: 'application/octet-stream',
        Headers.contentLengthHeader: bytes.length,
      },
      accept: const {200, 201, 204},
    );
  }

  /// Send the backup directly from disk rather than holding a ZIP in RAM.
  /// A fresh stream is needed if the server first asks for Digest auth.
  Future<void> putFile(String path, String filePath) async {
    final file = File(filePath);
    final length = await file.length();
    await _send(
      'PUT',
      path,
      bodyFactory: () => file.openRead(),
      headers: {
        Headers.contentTypeHeader: 'application/octet-stream',
        Headers.contentLengthHeader: length,
      },
      accept: const {200, 201, 204},
    );
  }

  /// Save a bounded response to a sibling temporary file. A failed download,
  /// an oversized stream, or an incomplete 206 must not overwrite a backup.
  Future<void> getFile(
    String path,
    String filePath, {
    int maxBytes = maxBackupBytes,
  }) async {
    final response = await _send(
      'GET',
      path,
      responseType: ResponseType.stream,
      accept: const {200, 206},
    );
    final data = response.data;
    if (data is! ResponseBody) {
      throw DAVException(
        method: 'GET',
        path: path,
        reasonPhrase: 'missing body',
      );
    }
    final random = Random.secure();
    final suffix =
        '${random.nextInt(1 << 32).toRadixString(16)}'
        '${random.nextInt(1 << 32).toRadixString(16)}';
    final staging = File('$filePath.$pid.$suffix.tmp');
    RandomAccessFile? writer;
    try {
      final declared = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      if (declared != null && declared > maxBytes) {
        await data.stream.listen(null).cancel();
        throw DAVException(
          method: 'GET',
          path: path,
          reasonPhrase: 'backup exceeds download limit',
        );
      }
      await staging.parent.create(recursive: true);
      writer = await staging.open(mode: FileMode.write);
      var received = 0;
      await for (final chunk in data.stream) {
        if (chunk.length > maxBytes - received) {
          throw DAVException(
            method: 'GET',
            path: path,
            reasonPhrase: 'backup exceeds download limit',
          );
        }
        // Wait for disk I/O so a slow disk cannot queue the entire download.
        await writer.writeFrom(chunk);
        received += chunk.length;
      }
      // A short 200 must not replace an existing backup with a truncated ZIP.
      // Compressed responses may report the wire length, not decoded bytes.
      if (declared != null &&
          (response.headers.value('content-encoding') ?? 'identity') ==
              'identity' &&
          received != declared) {
        throw DAVException(
          method: 'GET',
          path: path,
          reasonPhrase: 'response length does not match Content-Length',
        );
      }
      if (response.statusCode == 206 &&
          !_coversWhole(response.headers.value('content-range'), received)) {
        throw DAVException(
          method: 'GET',
          path: path,
          statusCode: 206,
          reasonPhrase: 'incomplete content range',
        );
      }
      await writer.flush();
      await writer.close();
      writer = null;
      await staging.rename(filePath);
    } catch (_) {
      if (writer != null) {
        try {
          await writer.close();
        } catch (_) {}
      }
      try {
        if (await staging.exists()) await staging.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<Uint8List> get(String path) async {
    final response = await _send(
      'GET',
      path,
      responseType: ResponseType.bytes,
      accept: const {200, 206},
    );
    final data = response.data;
    final bytes = data is List<int> ? Uint8List.fromList(data) : Uint8List(0);
    if (response.statusCode == 206 &&
        !_coversWhole(response.headers.value('content-range'), bytes.length)) {
      throw DAVException(
        method: 'GET',
        path: path,
        statusCode: 206,
        reasonPhrase: response.statusMessage,
      );
    }
    return bytes;
  }

  /// Some servers answer a plain GET with a 206 that spans the whole object.
  static bool _coversWhole(String? contentRange, int length) {
    final match = RegExp(
      r'^bytes\s+(\d+)-(\d+)/(\d+)$',
      caseSensitive: false,
    ).firstMatch(contentRange?.trim() ?? '');
    if (match == null) {
      return false;
    }
    final start = int.tryParse(match[1]!);
    final end = int.tryParse(match[2]!);
    final total = int.tryParse(match[3]!);
    if (start == null || end == null || total == null) {
      return false;
    }
    return start == 0 && end == total - 1 && total == length;
  }

  Future<Response<dynamic>> _send(
    String method,
    String path, {
    bool collection = false,
    List<int>? body,
    Stream<List<int>> Function()? bodyFactory,
    Map<String, dynamic> headers = const {},
    ResponseType responseType = ResponseType.plain,
    required Set<int> accept,
  }) async {
    final origin = resolve(path, collection: collection);
    var uri = origin;
    var retriedAuth = false;
    for (var redirects = 0; ; redirects++) {
      final response = await _request(
        method,
        uri,
        origin: origin,
        body: body,
        bodyFactory: bodyFactory,
        headers: headers,
        responseType: responseType,
      );
      final status = response.statusCode;
      if (status != null && accept.contains(status)) {
        return response;
      }
      // A redirected OPTIONS may land on another origin, whose challenge is
      // not this server's.
      if (status == 401 &&
          !retriedAuth &&
          _sameOrigin(uri, origin) &&
          _adoptChallenge(response)) {
        await _discardStream(response);
        retriedAuth = true;
        continue;
      }
      final location = _redirectTarget(response);
      if (location != null && redirects < _maxRedirects) {
        final next = uri.resolveUri(location);
        if (_isAllowedRedirect(
          method,
          current: uri,
          origin: origin,
          next: next,
        )) {
          await _discardStream(response);
          uri = next;
          continue;
        }
      }
      await _discardStream(response);
      throw DAVException(
        method: method,
        path: path,
        statusCode: status,
        reasonPhrase: response.statusMessage,
      );
    }
  }

  /// Cancel a streamed error/redirect before retrying; the request can hold
  /// an open connection even though the response body will never be read.
  static Future<void> _discardStream(Response<dynamic> response) async {
    final body = response.data;
    if (body is ResponseBody) {
      await body.stream.listen(null).cancel();
    }
  }

  static bool _isAllowedRedirect(
    String method, {
    required Uri current,
    required Uri origin,
    required Uri next,
  }) {
    if (next.scheme != 'http' && next.scheme != 'https') {
      return false;
    }
    if ((origin.scheme == 'https' || current.scheme == 'https') &&
        next.scheme != 'https') {
      return false;
    }
    // Only the reachability probe may leave the origin: a MKCOL, PUT or GET
    // answered elsewhere would report a change or a file this server lacks.
    return method == 'OPTIONS' || _sameOrigin(next, origin);
  }

  Future<Response<dynamic>> _request(
    String method,
    Uri uri, {
    required Uri origin,
    List<int>? body,
    Stream<List<int>> Function()? bodyFactory,
    required Map<String, dynamic> headers,
    required ResponseType responseType,
  }) {
    return _dio.requestUri<dynamic>(
      uri,
      data: bodyFactory?.call() ?? body,
      options: Options(
        method: method,
        headers: {...headers, ..._authorization(method, uri, origin)},
        responseType: responseType,
        // Redirects are followed by hand so that a PUT stays a PUT, and every
        // status reaches the caller instead of becoming a DioException.
        followRedirects: false,
        maxRedirects: 0,
        validateStatus: (_) => true,
      ),
    );
  }

  Uri? _redirectTarget(Response<dynamic> response) {
    const redirects = {301, 302, 303, 307, 308};
    if (!redirects.contains(response.statusCode)) {
      return null;
    }
    final location = response.headers.value('location');
    if (location == null || location.isEmpty) {
      return null;
    }
    return Uri.tryParse(location);
  }

  bool _adoptChallenge(Response<dynamic> response) {
    // Basic and Digest may each arrive as their own www-authenticate line.
    final headerValues = response.headers[Headers.wwwAuthenticateHeader];
    if (headerValues == null) {
      return false;
    }
    for (final header in headerValues) {
      final challenge = _DigestChallenge.parse(header);
      if (challenge != null) {
        _digest = challenge;
        _digestNonceCount = 0;
        return true;
      }
    }
    return false;
  }

  static bool _sameOrigin(Uri a, Uri b) {
    return a.scheme == b.scheme && a.host == b.host && _port(a) == _port(b);
  }

  static int _port(Uri uri) {
    if (uri.hasPort) return uri.port;
    return uri.scheme == 'https' ? 443 : 80;
  }

  Map<String, dynamic> _authorization(String method, Uri uri, Uri origin) {
    // Never forward credentials to a redirect target on another origin.
    if (!_sameOrigin(uri, origin)) {
      return const {};
    }
    if (user.isEmpty && password.isEmpty) {
      return const {};
    }
    final digest = _digest;
    if (digest == null) {
      final credentials = base64.encode(utf8.encode('$user:$password'));
      return {'authorization': 'Basic $credentials'};
    }
    return {
      'authorization': digest.authorize(
        user: user,
        password: password,
        method: method,
        uri: uri,
        nonceCount: ++_digestNonceCount,
      ),
    };
  }
}

class _DigestChallenge {
  const _DigestChallenge({
    required this.realm,
    required this.nonce,
    this.qop,
    this.opaque,
    this.algorithm,
  });

  final String realm;
  final String nonce;
  final String? qop;
  final String? opaque;
  final String? algorithm;

  static bool _hasLineBreak(String? value) =>
      value != null && (value.contains('\r') || value.contains('\n'));

  static String _quoteHeaderValue(String value) {
    if (_hasLineBreak(value)) {
      throw const FormatException('Invalid header value');
    }
    final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  static _DigestChallenge? parse(String? header) {
    if (header == null) return null;
    final start = header.toLowerCase().indexOf('digest');
    if (start == -1) return null;
    final values = <String, String>{};
    final pattern = RegExp(r'(\w+)\s*=\s*(?:"([^"]*)"|([^\s,]+))');
    for (final match in pattern.allMatches(header.substring(start + 6))) {
      values[match.group(1)!.toLowerCase()] = match.group(2) ?? match.group(3)!;
    }
    final nonce = values['nonce'];
    if (nonce == null) return null;
    final realm = values['realm'] ?? '';
    final opaque = values['opaque'];
    if (_hasLineBreak(realm) || _hasLineBreak(nonce) || _hasLineBreak(opaque)) {
      return null;
    }
    final algorithm = values['algorithm'];
    // Only MD5 is implemented; anything else would produce a wrong response
    // hash, and Basic at least has a chance of being accepted.
    if (algorithm != null && algorithm.toUpperCase() != 'MD5') {
      return null;
    }
    return _DigestChallenge(
      realm: realm,
      nonce: nonce,
      qop: _pickQop(values['qop']),
      opaque: opaque,
      algorithm: algorithm,
    );
  }

  static String? _pickQop(String? raw) {
    if (raw == null) return null;
    final options = raw.split(',').map((item) => item.trim().toLowerCase());
    return options.contains('auth') ? 'auth' : null;
  }

  String authorize({
    required String user,
    required String password,
    required String method,
    required Uri uri,
    required int nonceCount,
  }) {
    final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    final ha1 = '$user:$realm:$password'.toMd5();
    final ha2 = '$method:$path'.toMd5();
    final count = nonceCount.toRadixString(16).padLeft(8, '0');
    final cnonce = _cnonce();
    final response = qop == null
        ? '$ha1:$nonce:$ha2'.toMd5()
        : '$ha1:$nonce:$count:$cnonce:$qop:$ha2'.toMd5();
    final parts = [
      'username=${_quoteHeaderValue(user)}',
      'realm=${_quoteHeaderValue(realm)}',
      'nonce=${_quoteHeaderValue(nonce)}',
      'uri=${_quoteHeaderValue(path)}',
      'response="$response"',
      if (algorithm != null) 'algorithm=$algorithm',
      if (opaque != null) 'opaque=${_quoteHeaderValue(opaque!)}',
      if (qop != null) 'qop=$qop',
      if (qop != null) 'nc=$count',
      if (qop != null) 'cnonce="$cnonce"',
    ];
    return 'Digest ${parts.join(', ')}';
  }

  static String _cnonce() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}
