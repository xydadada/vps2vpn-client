import 'dart:io';

import 'package:fl_clash/vps2vpn/auto_update.dart';
import 'package:fl_clash/vps2vpn/update_integrity.dart';
import 'package:flutter_test/flutter_test.dart';

// Throwaway public key and signature shared with release_download_test.
const _key = 'f5be85b6ef9f1a0df2c79f83de5af4b290597411d85f7271acddf4a547a9dc78';
const _name = 'vps2vpn-1.0.9-windows-amd64-setup.exe';
const _signature =
    'bbD6sNdlQp50rGP2o5n3AbqubRpAyEu8G+9iw7nw6Z6+BjX6PgVJB5lM3VKfKilITHzrjUYxUZlHtpVUoSfEDQ==';

void main() {
  late Directory dir;
  late File installer;
  late File signature;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('v2v-integrity-');
    installer = File('${dir.path}/$_name');
    signature = File('${installer.path}.sig');
    await installer.writeAsString('release payload');
    await signature.writeAsString(_signature);
  });
  tearDown(() => dir.delete(recursive: true));

  Future<bool> verify() =>
      vpsVerifyInstaller(installer.path, publicKeyHex: _key);

  test(
    'accepts the exact signed bytes and refuses the production key',
    () async {
      expect(await verify(), isTrue);
      expect(await vpsVerifyInstaller(installer.path), isFalse);
    },
  );

  test('rechecks after an earlier successful restore', () async {
    expect(
      await vpsReadyInstaller(dir, '1.0.8', publicKeyHex: _key),
      isNotNull,
    );
    await installer.writeAsString('changed payload');
    expect(await verify(), isFalse);
  });

  test('binds the signature to the installer file name', () async {
    final moved = await installer.rename('${dir.path}/other-setup.exe');
    await signature.rename('${moved.path}.sig');
    expect(await vpsVerifyInstaller(moved.path, publicKeyHex: _key), isFalse);
  });

  for (final bad in ['', 'invalid signature', 'x' * 4097]) {
    test(
      'rejects invalid or excessive signature bytes (${bad.length})',
      () async {
        await signature.writeAsString(bad);
        expect(await verify(), isFalse);
        expect(
          await vpsReadyInstaller(dir, '1.0.8', publicKeyHex: _key),
          isNull,
        );
      },
    );
  }

  test('rejects a missing or malformed UTF-8 signature', () async {
    await signature.delete();
    expect(await verify(), isFalse);
    await signature.writeAsBytes([255]);
    expect(await verify(), isFalse);
  });

  test('rejects an empty or oversized installer before reading it', () async {
    final handle = await installer.open(mode: FileMode.write);
    try {
      expect(await verify(), isFalse);
      await handle.truncate(vpsInstallerMaxBytes + 1);
      expect(await verify(), isFalse);
    } finally {
      await handle.close();
    }
  });

  for (final target in ['installer', 'signature']) {
    test('rejects a $target symlink even when its target is signed', () async {
      if (Platform.isWindows) return;
      final file = target == 'installer' ? installer : signature;
      final kept = await file.rename('${file.path}.saved');
      await Link(file.path).create(kept.path);
      expect(await verify(), isFalse);
      expect(await vpsReadyInstaller(dir, '1.0.8', publicKeyHex: _key), isNull);
    });

    test('rejects a $target directory', () async {
      final file = target == 'installer' ? installer : signature;
      await file.delete();
      await Directory(file.path).create();
      expect(await verify(), isFalse);
    });

    test('rejects a $target FIFO without opening it', () async {
      if (Platform.isWindows) return;
      final file = target == 'installer' ? installer : signature;
      await file.delete();
      final result = await Process.run('mkfifo', [file.path]);
      expect(result.exitCode, 0);
      expect(await verify().timeout(const Duration(seconds: 5)), isFalse);
    });
  }
}
