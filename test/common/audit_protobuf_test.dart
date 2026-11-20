import 'dart:typed_data';

import 'package:fl_clash/common/mitm_protobuf.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a valid uint64 maximum remains readable', () {
    expect(
      mitmProtobufText(Uint8List.fromList([0x08, ...List.filled(9, 0xff), 1])),
      '1: 18446744073709551615',
    );
  });

  test('a varint cannot carry bits beyond uint64 in its tenth byte', () {
    expect(
      mitmProtobufText(Uint8List.fromList([0x08, ...List.filled(9, 0xff), 2])),
      isNull,
    );
  });

  test('an int64 length cannot wrap into a negative body offset', () {
    expect(
      mitmProtobufText(
        Uint8List.fromList([0x0a, ...List.filled(8, 0xff), 0x7f]),
      ),
      isNull,
    );
  });

  test('a cut message retains completed fields before an invalid length', () {
    final bytes = Uint8List.fromList([
      0x08,
      1,
      0x12,
      ...List.filled(8, 0xff),
      0x7f,
    ]);
    expect(mitmProtobufText(bytes), isNull);
    expect(mitmProtobufText(bytes, cut: true), '1: 1');
  });
}
