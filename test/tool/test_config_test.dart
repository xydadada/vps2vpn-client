import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/src/test_config.dart';

void main() {
  late Directory root;
  late String bundles;

  File write(String path) {
    final file = File(p.join(root.path, path));
    file.parent.createSync(recursive: true);
    return file..writeAsStringSync('');
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('flclash-test-config-');
    bundles = p.join(root.path, '.dart_tool', 'test_bundles');
    write('pubspec.yaml');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('selects the nearest configuration without chaining ancestors', () {
    write('flutter_test_config.dart');
    final parent = write('test/flutter_test_config.dart');
    final nested = write('test/nested/flutter_test_config.dart');

    expect(
      findTestConfiguration(write('test/one_test.dart').path),
      parent.path,
    );
    expect(
      findTestConfiguration(write('test/nested/two_test.dart').path),
      nested.path,
    );
  });

  test('stops at the nearest pubspec even when an ancestor has a config', () {
    write('flutter_test_config.dart');
    write('plugins/fixture/pubspec.yaml');

    expect(
      findTestConfiguration(write('plugins/fixture/test/one_test.dart').path),
      isNull,
    );
  });

  test('a configuration beside the nearest pubspec still applies', () {
    write('plugins/fixture/pubspec.yaml');
    final configuration = write('plugins/fixture/flutter_test_config.dart');

    expect(
      findTestConfiguration(write('plugins/fixture/test/one_test.dart').path),
      configuration.path,
    );
  });

  test('bundles the largest configuration group and isolates other files', () {
    final configuration = write('test/flutter_test_config.dart');
    write('test/nested/flutter_test_config.dart');
    final common = [
      write('test/one_test.dart').path,
      write('test/sub/two_test.dart').path,
    ];
    final different = write('test/nested/three_test.dart').path;
    final unconfigured = write('tool/four_test.dart').path;

    final plan = planTestConfiguration([
      different,
      ...common,
      unconfigured,
    ], bundleDirectory: bundles);

    expect(plan.configuration, configuration.path);
    expect(plan.bundled, common);
    expect(plan.standalone, [different, unconfigured]..sort());
  });

  test('unconfigured files can form the largest group without a forwarder', () {
    write('test/flutter_test_config.dart');
    final configured = write('test/one_test.dart').path;
    final plain = [
      write('tool/two_test.dart').path,
      write('tool/three_test.dart').path,
    ];
    final plan = planTestConfiguration([
      configured,
      ...plain,
    ], bundleDirectory: bundles);

    expect(plan.configuration, isNull);
    expect(plan.bundled, plain);
    expect(plan.standalone, [configured]);
    Directory(bundles).createSync(recursive: true);
    writeBundleConfiguration(bundles, plan.configuration);
    expect(
      File(p.join(bundles, 'flutter_test_config.dart')).existsSync(),
      isFalse,
    );
  });

  test(
    'does not give unconfigured files the bundle ancestor configuration',
    () {
      write('flutter_test_config.dart');
      write('plugins/fixture/pubspec.yaml');
      final plain = write('plugins/fixture/test/one_test.dart').path;

      final plan = planTestConfiguration([plain], bundleDirectory: bundles);

      expect(plan.bundled, isEmpty);
      expect(plan.standalone, [plain]);
      expect(plan.configuration, isNull);
    },
  );

  test('ignores a previous generated forwarder when planning the next run', () {
    write('.dart_tool/test_bundles/flutter_test_config.dart');
    final plain = write('test/one_test.dart').path;

    final plan = planTestConfiguration([plain], bundleDirectory: bundles);

    expect(plan.configuration, isNull);
    expect(plan.bundled, [plain]);
    expect(plan.standalone, isEmpty);
  });

  test('keeps configuration ties deterministic in input order', () {
    final first = write('test/first/flutter_test_config.dart');
    write('test/second/flutter_test_config.dart');
    final one = write('test/first/one_test.dart').path;
    final two = write('test/second/two_test.dart').path;

    final plan = planTestConfiguration([one, two], bundleDirectory: bundles);

    expect(plan.configuration, first.path);
    expect(plan.bundled, [one]);
    expect(plan.standalone, [two]);
  });

  test('an annotation-only run needs no generated configuration', () {
    final plan = planTestConfiguration([], bundleDirectory: bundles);

    expect(plan.configuration, isNull);
    expect(plan.bundled, isEmpty);
    expect(plan.standalone, isEmpty);
  });

  test(
    'the forwarder exports the original entrypoint through a relative URI',
    () {
      final configuration = write('test/config space/flutter_test_config.dart');
      Directory(bundles).createSync(recursive: true);

      writeBundleConfiguration(bundles, configuration.path);

      final source = File(
        p.join(bundles, 'flutter_test_config.dart'),
      ).readAsStringSync();
      final match = RegExp(
        r'^export (.+) show testExecutable;\n$',
      ).firstMatch(source);
      expect(match, isNotNull);
      final uri = Uri.parse(jsonDecode(match![1]!) as String);
      expect(uri.isAbsolute, isFalse);
      expect(Directory(bundles).uri.resolveUri(uri), configuration.uri);
    },
  );
}
