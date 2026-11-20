import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final config = loadYaml(_read('build_config.yaml')) as YamlMap;
  final coreName = config['core_name'] as String;
  final helperName = config['helper_name'] as String;
  final outputDir = config['output_dir'] as String;

  for (final platform in ['linux', 'windows']) {
    test('$platform installs exactly the build hook artifacts', () {
      final cmake = _read('$platform/CMakeLists.txt');
      final extension = platform == 'windows' ? '.exe' : '';
      final artifactPath = RegExp(
        r'\$\{CORE_ARTIFACTS_DIR\}/([A-Za-z0-9_.-]+)',
      );
      final artifacts = artifactPath
          .allMatches(cmake)
          .map((match) => match[1]!)
          .toSet();

      expect(artifacts, {
        '$coreName$extension',
        '$helperName$extension',
        'manifest.json',
      });
      expect(
        cmake,
        contains('"\${CMAKE_CURRENT_SOURCE_DIR}/../$outputDir/$platform"'),
      );
    });
  }

  test('macOS stages the Core produced by the build hook', () {
    final project = _read('macos/Runner.xcodeproj/project.pbxproj');
    final fileRefs = RegExp(
      r'lastKnownFileType = "compiled.mach-o.executable"; '
      r'path = ([^;]+); sourceTree = BUILT_PRODUCTS_DIR;',
    ).allMatches(project).toList();
    expect(fileRefs, hasLength(1));
    expect(fileRefs.single[1], coreName);
    expect(project, contains('"\$(BUILT_PRODUCTS_DIR)/$coreName"'));
    expect(project, contains('ATTRIBUTES = (CodeSignOnCopy, );'));

    final stage = RegExp(
      r'name = "Stage Core";[\s\S]*?'
      r'shellScript = ("(?:\\.|[^"\\])*");',
    ).firstMatch(project);
    expect(stage, isNotNull);
    final shell = jsonDecode(stage![1]!) as String;
    expect(shell, contains('core="\$SRCROOT/../$outputDir/macos/$coreName"'));
    expect(shell, contains('cp -f "\$core" "\$BUILT_PRODUCTS_DIR/$coreName"'));
  });
}
