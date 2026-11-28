import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'AppImage staging remains readable with a private build umask',
    () async {
      final temp = Directory.systemTemp.createTempSync('appimage_modes_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final fixture = File(p.join(temp.path, 'stage.dart'));
      fixture.writeAsStringSync('''
import 'dart:io';
import 'package:fl_clash/common/release_asset.dart';
import '${File('tool/src/package/context.dart').absolute.uri}';
import '${File('tool/src/package/linux.dart').absolute.uri}';
import '${File('tool/src/package/steps.dart').absolute.uri}';

Future<void> main(List<String> args) async {
  final root = args.single;
  void write(String path, String text) {
    final file = File('\$root/\$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }
  write('linux/CMakeLists.txt',
      'set(BINARY_NAME "sampleapp")\\nset(APPLICATION_ID "test.app")\\n');
  write('linux/packaging/appimage/make_config.yaml',
      'display_name: Test\\nicon: icon.png\\n');
  write('icon.png', 'fixture');
  final context = PackageContext(
    root: root, os: ReleaseOs.linux, arch: ReleaseArch.amd64,
    line: ReleaseLine.dev, version: '1.0.0', channel: 'dev', commit: 'fixture',
    pubspecVersion: '1.0.0+1', description: 'Test',
    outputDirectory: '\$root/dist',
  );
  final bundle = linuxBundlePath(context);
  Directory('\$bundle/lib').createSync(recursive: true);
  File('/bin/true').copySync('\$bundle/lib/libflutter_linux_gtk.so');
  File('/bin/true').copySync('\$bundle/sampleapp');
  for (final step in planAppImage(context).steps) {
    if (step is Command && step.executable == 'appimagetool') break;
    await step.run(verbose: false);
  }
}
''');
      final result = await Process.run('sh', [
        '-c',
        r'umask 077; exec "$@"',
        'sh',
        'dart',
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        fixture.path,
        temp.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final appDir = p.join(
        temp.path,
        'dist/.staging/appimage/sampleapp.AppDir',
      );
      for (final entity in Directory(appDir).listSync(recursive: true)) {
        final mode = entity.statSync().mode & 0x1ff;
        expect(mode & 0x124, 0x124, reason: '${entity.path} must be readable');
        expect(mode & 0x12, 0, reason: '${entity.path} must not be writable');
        if (entity is Directory || p.basename(entity.path) == 'AppRun') {
          expect(
            mode & 0x49,
            0x49,
            reason: '${entity.path} must be executable',
          );
        }
      }
    },
    skip: !Platform.isLinux,
  );
}
