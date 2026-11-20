import 'dart:io';
import 'dart:math';

const _replaceAttempts = 10;
const _replaceRetryDelay = Duration(milliseconds: 50);

/// The prefix mihomo's `age.DecryptBytes` tells an encrypted config by.
const _ageArmorHeader = '-----BEGIN AGE ENCRYPTED FILE-----';

extension FileExt on File {
  Future<void> safeCopy(String newPath) async {
    if (!await exists()) {
      return;
    }
    final targetFile = File(newPath);
    if (!await targetFile.exists()) {
      await targetFile.create(recursive: true);
    }
    await copy(newPath);
  }

  Future<bool> get isAgeEncrypted async {
    final head = await openRead(
      0,
      _ageArmorHeader.length,
    ).expand((chunk) => chunk).toList();
    return String.fromCharCodes(head) == _ageArmorHeader;
  }

  Future<File> safeWriteAsString(String str) async {
    if (!await exists()) {
      await create(recursive: true);
    }
    return writeAsString(str);
  }

  Future<File> safeWriteAsBytes(List<int> bytes) async {
    if (!await exists()) {
      await create(recursive: true);
    }
    return writeAsBytes(bytes);
  }

  /// Each write needs its own temporary sibling. Sharing one temp name lets
  /// overlapping writers truncate or rename each other's staging file.
  Future<void> writeAsStringAtomically(String content) async {
    final random = Random.secure();
    final suffix = random.nextInt(1 << 32).toRadixString(36) +
        random.nextInt(1 << 32).toRadixString(36);
    final temp = File('$path.$pid.$suffix.tmp');
    try {
      await temp.parent.create(recursive: true);
      await temp.writeAsString(content, flush: true);
      await temp.renameReplacing(path);
    } catch (_) {
      await temp.delete().then((_) {}, onError: (_) {});
      rethrow;
    }
  }

  Future<void> renameReplacing(
    String target, {
    void Function()? beforeAttempt,
  }) async {
    for (var attempt = 1; ; attempt++) {
      beforeAttempt?.call();
      try {
        await rename(target);
        return;
      } on FileSystemException {
        if (attempt == _replaceAttempts) rethrow;
        await Future<void>.delayed(_replaceRetryDelay);
      }
    }
  }
}

extension FileSystemEntityExt on FileSystemEntity {
  Future<void> safeDelete({bool recursive = false}) async {
    if (!await exists()) {
      return;
    }
    await delete(recursive: recursive);
  }
}

Future<void> safeDeletePath(String path) async {
  final entity = switch (FileSystemEntity.typeSync(path, followLinks: false)) {
    FileSystemEntityType.directory => Directory(path),
    FileSystemEntityType.link => Link(path),
    _ => File(path),
  };
  await entity.safeDelete(recursive: true);
}
