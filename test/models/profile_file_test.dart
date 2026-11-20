import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  const profile = Profile(id: 42, autoUpdateDuration: Duration(days: 1));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('profile_file_test');
    await useAppPaths(root);
  });

  tearDown(() => root.delete(recursive: true));

  test('rejected validation removes staging and keeps the old profile', () async {
    final original = await profile.file;
    await original.writeAsString('old profile');
    String? staged;
    await expectLater(
      profile.saveFile(
        utf8.encode('new credentials'),
        validate: (path, _) async {
          staged = path;
          expect(await File(path).readAsString(), 'new credentials');
          return 'invalid profile';
        },
      ),
      throwsA(isA<MessageException>()),
    );
    expect(staged, isNotNull);
    expect(await File(staged!).exists(), isFalse);
    expect(await original.readAsString(), 'old profile');
  });

  test('a validator exception also removes staging', () async {
    String? staged;
    await expectLater(
      profile.saveFile(
        utf8.encode('credentials'),
        validate: (path, _) async {
          staged = path;
          throw StateError('core disconnected');
        },
      ),
      throwsStateError,
    );
    expect(staged, isNotNull);
    expect(await File(staged!).exists(), isFalse);
  });

  test('successful validation copies the profile and removes staging', () async {
    String? staged;
    final saved = await profile.saveFile(
      utf8.encode('new profile'),
      validate: (path, _) async {
        staged = path;
        return null;
      },
    );
    expect(saved.lastUpdateDate, isNotNull);
    expect(await (await saved.file).readAsString(), 'new profile');
    expect(await File(staged!).exists(), isFalse);
  });
}
