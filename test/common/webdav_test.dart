import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/webdav.dart';
import 'package:flutter_test/flutter_test.dart';

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this._responses);

  final ResponseBody Function(RequestOptions options) _responses;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return _responses(options);
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_ScriptedAdapter adapter) => Dio()..httpClientAdapter = adapter;

void main() {
  for (final destination in [
    'https://other.example/backup.zip',
    'http://origin.example/backup.zip',
    'https://origin.example:8443/backup.zip',
  ]) {
    test('an upload never replays its body to $destination', () async {
      final adapter = _ScriptedAdapter(
        (_) => ResponseBody.fromString(
          '',
          307,
          headers: {
            'location': [destination],
          },
        ),
      );
      final transport = DAVTransport(
        uri: 'https://origin.example/base',
        user: 'user',
        password: 'pass',
        dio: _dioWith(adapter),
      );

      await expectLater(
        transport.put('backup.zip', [1, 2, 3]),
        throwsA(isA<DAVException>()),
      );

      expect(adapter.requests, hasLength(1));
    });
  }

  test(
    'an upload keeps its method and bytes on a same-origin redirect',
    () async {
      var calls = 0;
      final adapter = _ScriptedAdapter((_) {
        calls++;
        return calls == 1
            ? ResponseBody.fromString(
                '',
                307,
                headers: {
                  'location': ['/moved/backup.zip'],
                },
              )
            : ResponseBody.fromString('', 201);
      });
      final transport = DAVTransport(
        uri: 'https://origin.example/base',
        user: 'user',
        password: 'pass',
        dio: _dioWith(adapter),
      );

      await transport.put('backup.zip', [1, 2, 3]);

      expect(adapter.requests, hasLength(2));
      expect(adapter.requests.last.method, 'PUT');
      expect(adapter.requests.last.data, [1, 2, 3]);
      expect(adapter.requests.last.uri.path, '/moved/backup.zip');
      expect(adapter.requests.last.headers, contains('authorization'));
    },
  );

  test(
    'a foreign challenge never replaces the origin authentication',
    () async {
      var calls = 0;
      final adapter = _ScriptedAdapter((_) {
        calls++;
        return switch (calls) {
          1 => ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': ['https://other.example/probe'],
            },
          ),
          2 => ResponseBody.fromString(
            '',
            401,
            headers: {
              'www-authenticate': ['Digest realm="foreign", nonce="other"'],
            },
          ),
          _ => ResponseBody.fromString('', 204),
        };
      });
      final transport = DAVTransport(
        uri: 'https://origin.example/base',
        user: 'user',
        password: 'pass',
        dio: _dioWith(adapter),
      );

      await expectLater(
        transport.options('probe'),
        throwsA(isA<DAVException>()),
      );
      await transport.options('probe');

      expect(adapter.requests, hasLength(3));
      expect(
        adapter.requests.last.headers['authorization'],
        startsWith('Basic '),
      );
    },
  );

  test(
    'redirect to a different origin drops the Authorization header',
    () async {
      var call = 0;
      final adapter = _ScriptedAdapter((options) {
        call++;
        if (call == 1) {
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': ['http://other.example/target'],
            },
          );
        }
        return ResponseBody.fromString('', 204);
      });
      final transport = DAVTransport(
        uri: 'http://origin.example/base',
        user: 'user',
        password: 'pass',
        dio: _dioWith(adapter),
      );

      await transport.options('probe');

      expect(adapter.requests, hasLength(2));
      expect(adapter.requests[0].headers, contains('authorization'));
      expect(adapter.requests[1].uri.host, 'other.example');
      expect(adapter.requests[1].headers, isNot(contains('authorization')));
    },
  );

  test(
    'redirect within the same origin keeps the Authorization header',
    () async {
      var call = 0;
      final adapter = _ScriptedAdapter((options) {
        call++;
        if (call == 1) {
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': ['http://origin.example/base/moved'],
            },
          );
        }
        return ResponseBody.fromString('', 204);
      });
      final transport = DAVTransport(
        uri: 'http://origin.example/base',
        user: 'user',
        password: 'pass',
        dio: _dioWith(adapter),
      );

      await transport.options('probe');

      expect(adapter.requests, hasLength(2));
      expect(adapter.requests[1].headers, contains('authorization'));
    },
  );

  test(
    'a Digest challenge is found even behind a Basic www-authenticate line',
    () async {
      var call = 0;
      final adapter = _ScriptedAdapter((options) {
        call++;
        if (call == 1) {
          return ResponseBody.fromString(
            '',
            401,
            headers: {
              'www-authenticate': [
                'Basic realm="x"',
                'Digest realm="y", nonce="abc123", qop="auth", opaque="op1"',
              ],
            },
          );
        }
        return ResponseBody.fromString('', 204);
      });
      final transport = DAVTransport(
        uri: 'http://origin.example/base',
        user: 'user',
        password: 'pass',
        dio: _dioWith(adapter),
      );

      await transport.options('probe');

      expect(adapter.requests, hasLength(2));
      final retryAuth = adapter.requests[1].headers['authorization'] as String;
      expect(retryAuth, startsWith('Digest '));
      expect(retryAuth, contains('realm="y"'));
    },
  );

  DAVTransport partialTransport(String contentRange) {
    final adapter = _ScriptedAdapter(
      (options) => ResponseBody.fromBytes(
        [1, 2, 3, 4],
        206,
        headers: {
          'content-range': [contentRange],
        },
      ),
    );
    return DAVTransport(
      uri: 'http://origin.example/base',
      user: 'user',
      password: 'pass',
      dio: _dioWith(adapter),
    );
  }

  test('a 206 that spans the whole object is read as the file', () async {
    final bytes = await partialTransport('bytes 0-3/4').get('backup.zip');

    expect(bytes, [1, 2, 3, 4]);
  });

  test('the bytes unit in Content-Range is case-insensitive', () async {
    final bytes = await partialTransport('Bytes 0-3/4').get('backup.zip');

    expect(bytes, [1, 2, 3, 4]);
  });

  test('a 206 that covers only part of the object fails', () async {
    await expectLater(
      partialTransport('bytes 0-3/10').get('backup.zip'),
      throwsA(isA<DAVException>()),
    );
  });
}
