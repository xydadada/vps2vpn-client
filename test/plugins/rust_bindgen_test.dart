import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../plugins/rust_api/hook/libclang.dart';

void main() {
  late Directory root;
  late Uri compiler;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bindgen-test-');
    compiler = root.uri.resolve('ndk/bin/clang');
  });

  tearDown(() => root.deleteSync(recursive: true));

  File library(String relative) =>
      File.fromUri(root.uri.resolve(relative))..createSync(recursive: true);

  test('prefers a libclang supplied by the selected NDK', () {
    final ndk = library('ndk/lib/libclang.so');
    final host = library('host/libclang.so.18.1');
    expect(
      androidBindgenEnvironment(
        compiler,
        environment: {'LIBCLANG_PATH': host.parent.path},
      ),
      {'LIBCLANG_PATH': ndk.parent.path},
    );
  });

  test('supports the older NDK lib64 layout', () {
    final ndk = library('ndk/lib64/libclang.so');
    expect(androidBindgenEnvironment(compiler, environment: const {}), {
      'LIBCLANG_PATH': ndk.parent.path,
    });
  });

  test('uses an explicit host library when the NDK omits libclang', () {
    final host = library('host/libclang-18.so.1');
    expect(
      androidBindgenEnvironment(
        compiler,
        environment: {'LIBCLANG_PATH': host.parent.path},
      ),
      {'LIBCLANG_PATH': host.parent.path},
    );
    expect(
      androidBindgenEnvironment(
        compiler,
        environment: {'LIBCLANG_PATH': host.path},
      ),
      {'LIBCLANG_PATH': host.path},
    );
  });

  test('rejects missing libraries and libclang-cpp as a substitute', () {
    final cpp = library('host/libclang-cpp.so.18');
    for (final configured in [cpp.parent.path, '${root.path}/missing']) {
      expect(
        () => androidBindgenEnvironment(
          compiler,
          environment: {'LIBCLANG_PATH': configured},
        ),
        throwsStateError,
      );
    }
  });
}
