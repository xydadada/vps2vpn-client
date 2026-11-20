import 'dart:io';

Map<String, String> androidBindgenEnvironment(
  Uri compiler, {
  Map<String, String>? environment,
}) {
  final llvmRoot = File.fromUri(compiler).parent.parent;
  for (final name in const ['lib', 'lib64']) {
    final directory = '${llvmRoot.path}${Platform.pathSeparator}$name';
    if (_containsLibclang(directory)) return {'LIBCLANG_PATH': directory};
  }
  final configured = (environment ?? Platform.environment)['LIBCLANG_PATH'];
  if (configured != null && _containsLibclang(configured)) {
    return {'LIBCLANG_PATH': configured};
  }
  throw StateError(
    'No libclang under ${llvmRoot.path} (lib or lib64); install a host '
    'libclang and set LIBCLANG_PATH to its library directory',
  );
}

final _libraryName = RegExp(
  r'^(libclang(?:-[0-9]+(?:\.[0-9]+)*)?\.(?:so(?:\.[0-9]+)*|dylib|dll)|clang\.dll)$',
);

bool _containsLibclang(String path) {
  bool usable(FileSystemEntity entity) =>
      _libraryName.hasMatch(entity.uri.pathSegments.last) &&
      File(entity.path).existsSync();
  final directory = Directory(path);
  if (directory.existsSync()) return directory.listSync().any(usable);
  return usable(File(path));
}
