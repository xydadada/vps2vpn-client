import 'dart:async';
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

  test(
    'rejected validation removes staging and keeps the old profile',
    () async {
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
    },
  );

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

  test(
    'successful validation publishes the profile and removes staging',
    () async {
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
    },
  );

  test('an obsolete validation cannot publish its bytes', () async {
    final original = await profile.file;
    await original.writeAsString('old profile');
    final entered = Completer<void>();
    final validation = Completer<String?>();
    var current = true;
    String? staged;
    final pending = profile.saveFile(
      utf8.encode('obsolete credentials'),
      validate: (path, _) {
        staged = path;
        entered.complete();
        return validation.future;
      },
      shouldCommit: () => current,
    );
    await entered.future;
    current = false;
    validation.complete(null);

    final result = await pending;
    expect(result, profile);
    expect(await original.readAsString(), 'old profile');
    expect(await File(staged!).exists(), isFalse);
    expect(
      original.parent.listSync().whereType<File>().map((file) => file.path),
      [original.path],
    );
  });

  test('a newer save wins when an older validation finishes last', () async {
    final original = await profile.file;
    await original.writeAsString('old profile');
    final entered = Completer<void>();
    final validation = Completer<String?>();
    var generation = 1;
    final older = profile.saveFile(
      utf8.encode('older'),
      validate: (_, _) {
        entered.complete();
        return validation.future;
      },
      shouldCommit: () => generation == 1,
    );
    await entered.future;
    generation = 2;
    final newer = await profile.saveFile(
      utf8.encode('newer'),
      validate: (_, _) async => null,
      shouldCommit: () => generation == 2,
    );
    validation.complete(null);

    expect(await older, profile);
    expect(newer.lastUpdateDate, isNotNull);
    expect(await original.readAsString(), 'newer');
    expect(
      original.parent.listSync().whereType<File>().map((file) => file.path),
      [original.path],
    );
  });

  test(
    'a failed publication keeps the destination and removes staging',
    () async {
      final path = await appPath.getProfilePath(profile.id.toString());
      final destination = await Directory(path).create(recursive: true);
      final sentinel = File('${destination.path}/existing');
      await sentinel.writeAsString('keep');
      String? staged;

      await expectLater(
        profile.saveFile(
          utf8.encode('new credentials'),
          validate: (path, _) async {
            staged = path;
            return null;
          },
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(await sentinel.readAsString(), 'keep');
      expect(await File(staged!).exists(), isFalse);
      expect(destination.parent.listSync().map((entry) => entry.path), [
        destination.path,
      ]);
    },
  );
}
