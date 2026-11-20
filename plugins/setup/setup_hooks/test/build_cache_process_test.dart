import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:setup_hooks/src/build_cache.dart';
import 'package:test/test.dart';

void main() {
  test('waits for the build lock held by another process', () async {
    final root = await Directory.systemTemp.createTemp('setup_process_lock_');
    final cache = BuildCache(rootDir: root.path);
    final lockFile = File('${cache.cacheDir}/shared-core.lock');
    await lockFile.create(recursive: true);
    final lock = await lockFile.open(mode: FileMode.append);
    await lock.lock(FileLock.exclusive);
    Process? worker;
    StreamSubscription<String>? output;
    var unlocked = false;
    try {
      worker = await Process.start(Platform.resolvedExecutable, [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        File('test/fixtures/build_cache_worker.dart').absolute.path,
        root.path,
      ]);
      final ready = Completer<void>();
      output = worker.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line == 'ready' && !ready.isCompleted) ready.complete();
          });
      final errors = worker.stderr.transform(utf8.decoder).join();
      final exited = worker.exitCode;
      await ready.future.timeout(const Duration(seconds: 10));
      final earlyExit = await Future.any<int?>([
        exited,
        Future<int?>.delayed(const Duration(milliseconds: 200)),
      ]);
      expect(earlyExit, isNull, reason: 'a contending build must wait');
      await lock.unlock();
      unlocked = true;
      expect(await exited.timeout(const Duration(seconds: 10)), 0);
      expect(await errors, isEmpty);
      expect(await File('${root.path}/core').readAsString(), 'complete');
    } finally {
      if (!unlocked) await lock.unlock();
      await lock.close();
      worker?.kill();
      if (worker != null) await worker.exitCode;
      await output?.cancel();
      await root.delete(recursive: true);
    }
  });
}
