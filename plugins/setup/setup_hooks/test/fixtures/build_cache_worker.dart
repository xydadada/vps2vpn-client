import 'dart:io';

import 'package:setup_hooks/src/build_cache.dart';
import 'package:setup_hooks/src/fingerprint.dart';

Future<void> main(List<String> args) async {
  final root = args.single;
  final output = File('$root/core');
  stdout.writeln('ready');
  await BuildCache(rootDir: root).run(
    key: 'shared-core',
    fingerprint: () async => const Fingerprint('shared-input'),
    primaryOutput: output.path,
    build: () async {
      await output.writeAsString('complete');
      return [output.path];
    },
    notice: BuildNotice(),
  );
}
