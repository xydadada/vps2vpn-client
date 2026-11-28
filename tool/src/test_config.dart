import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

String? findTestConfiguration(String test) {
  var directory = File(test).absolute.parent;
  while (directory.path != directory.parent.path) {
    final configuration = File(
      p.join(directory.path, 'flutter_test_config.dart'),
    );
    if (configuration.existsSync()) return p.normalize(configuration.path);
    if (File(p.join(directory.path, 'pubspec.yaml')).existsSync()) break;
    directory = directory.parent;
  }
  return null;
}

({List<String> bundled, List<String> standalone, String? configuration})
planTestConfiguration(List<String> files, {required String bundleDirectory}) {
  final groups = <String?, List<String>>{};
  for (final file in files) {
    groups.putIfAbsent(findTestConfiguration(file), () => []).add(file);
  }
  // The generated directory is replaced before each run; ignore its old config.
  final inherited = findTestConfiguration(
    p.join(p.dirname(bundleDirectory), 'bundle_test.dart'),
  );
  String? configuration;
  var bundled = <String>[];
  for (final entry in groups.entries) {
    if (entry.key == null && inherited != null) continue;
    if (entry.value.length > bundled.length) {
      configuration = entry.key;
      bundled = entry.value;
    }
  }
  return (
    bundled: bundled,
    standalone: [
      for (final entry in groups.entries)
        if (!identical(entry.value, bundled)) ...entry.value,
    ]..sort(),
    configuration: configuration,
  );
}

void writeBundleConfiguration(String directory, String? configuration) {
  if (configuration == null) return;
  final uri = p.toUri(p.relative(configuration, from: directory));
  final literal = jsonEncode(uri.toString()).replaceAll(r'$', r'\$');
  File(
    p.join(directory, 'flutter_test_config.dart'),
  ).writeAsStringSync('export $literal show testExecutable;\n');
}
