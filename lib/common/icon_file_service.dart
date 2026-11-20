import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

const maxIconBytes = 16 << 20;
const _iconTimeout = Duration(seconds: 30);

/// Bound actual bytes before the cache manager creates a file or a decoder runs.
Future<Uint8List> readIconBytes(
  Stream<List<int>> source, {
  int? declaredLength,
  int maxBytes = maxIconBytes,
  Duration timeout = _iconTimeout,
}) async {
  final iterator = StreamIterator(source);
  final clock = Stopwatch()..start();
  final bytes = BytesBuilder(copy: false);
  try {
    if (declaredLength != null && declaredLength > maxBytes) {
      throw const FormatException('Icon exceeds the byte limit');
    }
    while (true) {
      final remaining = timeout - clock.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Icon read timed out');
      }
      if (!await iterator.moveNext().timeout(remaining)) {
        return bytes.takeBytes();
      }
      final chunk = iterator.current;
      if (chunk.length > maxBytes - bytes.length) {
        throw const FormatException('Icon exceeds the byte limit');
      }
      bytes.add(chunk);
    }
  } finally {
    await iterator.cancel();
  }
}

/// A failed or oversized response never leaves an untracked partial cache file.
class IconFileService extends FileService {
  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final client = http.Client();
    final clock = Stopwatch()..start();
    try {
      final response = await HttpFileService(
        httpClient: client,
      ).get(url, headers: headers).timeout(_iconTimeout);
      final bytes = response.statusCode == 200 || response.statusCode == 202
          ? await readIconBytes(
              response.content,
              declaredLength: response.contentLength,
              timeout: _iconTimeout - clock.elapsed,
            )
          : Uint8List(0);
      return _BufferedIconResponse(response, bytes);
    } finally {
      client.close();
    }
  }
}

class _BufferedIconResponse implements FileServiceResponse {
  _BufferedIconResponse(this.response, this.bytes);

  final FileServiceResponse response;
  final Uint8List bytes;

  @override
  Stream<List<int>> get content => Stream.value(bytes);

  @override
  int get contentLength => bytes.length;

  @override
  int get statusCode => response.statusCode;

  @override
  DateTime get validTill => response.validTill;

  @override
  String? get eTag => response.eTag;

  @override
  String get fileExtension => response.fileExtension;
}
