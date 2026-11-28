import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/windows_safe_mode.dart';

String _encode(List<String> defines) =>
    defines.map((define) => base64.encode(utf8.encode(define))).join(',');

void main() {
  test('defaults to the same false value as bool.fromEnvironment', () {
    expect(windowsSafeMode(''), isFalse);
    expect(windowsSafeMode(_encode(['APP_ENV=stable'])), isFalse);
  });

  test('only the exact true value enables safe mode', () {
    expect(windowsSafeMode(_encode(['SAFE_MODE=true'])), isTrue);
    for (final value in [
      'false',
      '',
      'TRUE',
      '1',
      ' true',
      'true ',
      'true=1',
    ]) {
      expect(windowsSafeMode(_encode(['SAFE_MODE=$value'])), isFalse);
    }
  });

  test('the last definition wins, including invalid boolean values', () {
    expect(
      windowsSafeMode(_encode(['SAFE_MODE=false', 'SAFE_MODE=true'])),
      isTrue,
    );
    expect(
      windowsSafeMode(_encode(['SAFE_MODE=true', 'SAFE_MODE=false'])),
      isFalse,
    );
    expect(
      windowsSafeMode(_encode(['SAFE_MODE=true', 'SAFE_MODE=invalid'])),
      isFalse,
    );
  });

  test('other keys and their encoded contents cannot change the flag', () {
    expect(
      windowsSafeMode(
        _encode([
          'SAFE_MODE=true',
          'APP_ENV=stable,SAFE_MODE=false',
          'OTHER_SAFE_MODE=false',
          'SAFE_MODE_EXTRA=false',
          'safe_mode=false',
          'LABEL=示例;=值',
        ]),
      ),
      isTrue,
    );
    expect(windowsSafeMode(_encode(['OTHER=SAFE_MODE=true'])), isFalse);
  });

  test('malformed configuration fails instead of disabling safe mode', () {
    expect(() => windowsSafeMode('not-base64!'), throwsFormatException);
    expect(
      () => windowsSafeMode('${_encode(['SAFE_MODE=true'])},not-base64!'),
      throwsFormatException,
    );
    expect(() => windowsSafeMode(base64.encode([255])), throwsFormatException);
  });
}
