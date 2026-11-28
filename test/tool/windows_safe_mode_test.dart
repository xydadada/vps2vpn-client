import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the runner skips its stale-proxy sweep in a safe build', () {
    final cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();
    final encoded = RegExp(
      r'"([A-Za-z0-9+/=]+)" IN_LIST FLCLASH_DEFINES',
    ).firstMatch(cmake);
    expect(encoded, isNotNull);
    expect(utf8.decode(base64.decode(encoded![1]!)), 'SAFE_MODE=true');
    expect(cmake, contains('"FLCLASH_SAFE_MODE=\${FLCLASH_SAFE_MODE}"'));

    final runner = File('windows/runner/main.cpp').readAsStringSync();
    expect(
      runner,
      contains(
        'FLCLASH_SAFE_MODE ? std::thread{} : ClearStaleProxyInBackground()',
      ),
    );
  });
}
