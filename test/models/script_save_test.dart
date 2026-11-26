import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_paths.dart';

/// Models a full disk after opening and partially writing a real file.
final class _PartialWriteOverrides extends IOOverrides {
  @override
  File createFile(String path) => _PartialWriteFile(super.createFile(path));
}

class _PartialWriteFile extends Fake implements File {
  _PartialWriteFile(this.file);

  final File file;

  @override
  String get path => file.path;

  @override
  Directory get parent => file.parent;

  @override
  Future<bool> exists() => file.exists();

  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    await file.create(recursive: recursive, exclusive: exclusive);
    return this;
  }

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    await file.writeAsString(
      contents.substring(0, 3),
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
    throw FileSystemException('simulated full disk', path);
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  const original = 'const main = config => config;';
  const replacement = 'const main = config => ({...config, rules: []});';
  final script = Script(
    id: 17,
    label: 'Test script',
    lastUpdateTime: DateTime(2020),
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('script_save');
    await useAppPaths(root);
  });

  tearDown(() => root.delete(recursive: true));

  test(
    'first save creates the script directory and complete content',
    () async {
      final saved = await script.save(original);

      expect(await script.content, original);
      expect(saved.id, script.id);
      expect(saved.label, script.label);
      expect(saved.lastUpdateTime.isAfter(script.lastUpdateTime), isTrue);
    },
  );

  test(
    'replacement writes the complete script and leaves no staging file',
    () async {
      await script.save(original);
      await script.save(replacement);

      final file = File(await script.path);
      expect(await file.readAsString(), replacement);
      expect(file.parent.listSync().map((entry) => entry.path), [file.path]);
    },
  );

  test('partial write failure preserves the previous usable script', () async {
    await script.save(original);
    final file = File(await script.path);

    await expectLater(
      IOOverrides.runWithIOOverrides(
        () => script.save(replacement),
        _PartialWriteOverrides(),
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await file.readAsString(), original);
    expect(file.parent.listSync().map((entry) => entry.path), [file.path]);
  });
}
