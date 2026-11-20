import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('profile_save_test');
    await useAppPaths(tempDir);
  });

  tearDownAll(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('Profile.saveFile', () {
    // EditProfileView relies on this throwing rather than silently
    // succeeding, so a caller-level try/catch can surface the failure.
    test('rejects an invalid config without touching the saved file', () async {
      final profile = Profile.normal(label: 'p');
      final bytes = Uint8List.fromList(utf8.encode('bad: ['));

      await expectLater(
        profile.saveFile(bytes, validate: (_, _) async => 'invalid config'),
        throwsA(
          isA<MessageException>().having(
            (e) => e.message,
            'message',
            'invalid config',
          ),
        ),
      );

      final savedFile = File(
        await appPath.getProfilePath(profile.id.toString()),
      );
      expect(await savedFile.exists(), isFalse);
      expect(
        Directory(await appPath.profilesPath).listSync().whereType<Directory>(),
        isEmpty,
      );
    });

    test('copies validated bytes and stamps the update time', () async {
      final profile = Profile.normal(label: 'p');
      final bytes = Uint8List.fromList(utf8.encode('proxies: []'));

      final saved = await profile.saveFile(
        bytes,
        validate: (_, _) async => null,
      );

      expect(saved.lastUpdateDate, isNotNull);
      final savedFile = await profile.file;
      expect(await savedFile.readAsString(), 'proxies: []');
    });

    test('cleans staging and preserves the old config on failure', () async {
      final profile = Profile.normal(label: 'existing');
      final savedFile = await profile.file;
      await savedFile.writeAsString('proxies: []');
      String? validationPath;

      await expectLater(
        profile.saveFile(
          Uint8List.fromList(utf8.encode('password: secret')),
          validate: (path, _) async {
            validationPath = path;
            throw StateError('validator disconnected');
          },
        ),
        throwsStateError,
      );

      expect(await savedFile.readAsString(), 'proxies: []');
      expect(await File(validationPath!).exists(), isFalse);
      expect(await File(validationPath!).parent.exists(), isFalse);
    });

    test('validates a sibling before replacing the complete config', () async {
      final profile = Profile.normal(label: 'existing');
      final savedFile = await profile.file;
      await savedFile.writeAsString('old config');
      String? validationPath;

      await profile.saveFile(
        Uint8List.fromList(utf8.encode('new config')),
        validate: (path, _) async {
          validationPath = path;
          expect(File(path).parent.parent.path, savedFile.parent.path);
          expect(await File(path).readAsString(), 'new config');
          expect(await savedFile.readAsString(), 'old config');
          return null;
        },
      );

      expect(await savedFile.readAsString(), 'new config');
      expect(await File(validationPath!).parent.exists(), isFalse);
    });

    test('a newer file edit supersedes a pending validation', () async {
      final profile = Profile.normal(label: 'p');
      final entered = Completer<void>();
      final validation = Completer<String?>();
      final old = profile.saveFile(
        Uint8List.fromList('old'.codeUnits),
        validate: (_, _) {
          entered.complete();
          return validation.future;
        },
      );
      final superseded = expectLater(
        old,
        throwsA(isA<ProfileUpdateSuperseded>()),
      );
      await entered.future;
      await profile.saveFile(
        Uint8List.fromList('new'.codeUnits),
        validate: (_, _) async => null,
      );
      validation.complete(null);
      await superseded;
      expect(await (await profile.file).readAsString(), 'new');
    });

    test('a failed replacement does not poison later writes', () async {
      final profile = Profile.normal(label: 'p');
      final path = await appPath.getProfilePath(profile.id.toString());
      await Directory(path).create(recursive: true);
      await expectLater(
        profile.saveFile(
          Uint8List.fromList('first'.codeUnits),
          validate: (_, _) async => null,
        ),
        throwsA(isA<FileSystemException>()),
      );
      await Directory(path).delete();
      await profile.saveFile(
        Uint8List.fromList('second'.codeUnits),
        validate: (_, _) async => null,
      );
      expect(await (await profile.file).readAsString(), 'second');
    });

    test('deletion cancels an active replacement', () async {
      final profile = Profile.normal(label: 'p');
      final path = await appPath.getProfilePath(profile.id.toString());
      await Directory(path).create(recursive: true);
      final attempted = Completer<void>();
      var validated = false;
      final saving = profile.saveFile(
        Uint8List.fromList('pending'.codeUnits),
        validate: (_, _) async {
          validated = true;
          return null;
        },
        canCommit: () {
          if (validated && !attempted.isCompleted) attempted.complete();
          return true;
        },
      );
      final superseded = expectLater(
        saving,
        throwsA(isA<ProfileUpdateSuperseded>()),
      );
      await attempted.future;
      await deleteProfileFile(profile.id);
      await superseded;
      expect(await FileSystemEntity.type(path), FileSystemEntityType.notFound);
    });

    test('superseded writes are quiet UI cancellations', () async {
      final value = await globalState.safeRun<Profile>(() async {
        throw const ProfileUpdateSuperseded();
      });
      expect(value, isNull);
    });

    test('validates with the profile age key', () async {
      final profile = Profile.normal(
        label: 'p',
      ).copyWith(ageSecretKey: 'AGE-SECRET-KEY-1A');
      final bytes = Uint8List.fromList(utf8.encode('proxies: []'));
      String? ageSecretKey;

      await profile.saveFile(
        bytes,
        validate: (_, key) async {
          ageSecretKey = key;
          return null;
        },
      );

      expect(ageSecretKey, 'AGE-SECRET-KEY-1A');
    });
  });
}
