import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/print.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compactError compacts DioException to type and status code', () {
    final error = DioException(
      requestOptions: RequestOptions(path: '/'),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(path: '/'),
        statusCode: 403,
      ),
    );
    expect(compactError(error), 'DioException(badResponse, HTTP 403)');
  });

  test('compactError omits the status code when the response is missing', () {
    final error = DioException(
      requestOptions: RequestOptions(path: '/'),
      type: DioExceptionType.connectionError,
    );
    expect(compactError(error), 'DioException(connectionError)');
  });

  test('compactError keeps the parse reason, not the parsed text', () {
    const damaged = '{"password":"test-secret" trailing}';
    late FormatException error;
    try {
      jsonDecode(damaged);
    } on FormatException catch (e) {
      error = e;
    }
    expect(error.toString(), contains('test-secret'));
    expect(compactError(error), startsWith('FormatException('));
    expect(compactError(error), isNot(contains('test-secret')));
  });

  test('compactError keeps other exception messages', () {
    expect(compactError(StateError('boom')), contains('boom'));
  });
}
