import 'dart:io';

import 'package:fl_clash/common/release_asset.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/src/package/context.dart';
import '../../tool/src/package/linux.dart';

void main() {
  for (final mask in ['022', '077']) {
    test(
      'RPM install tree normalizes private staged files with umask $mask',
      () async {
        final temp = Directory.systemTemp.createTempSync('rpm_modes_');
        addTearDown(() => temp.deleteSync(recursive: true));
        final context = PackageContext(
          root: Directory.current.path,
          os: ReleaseOs.linux,
          arch: ReleaseArch.amd64,
          line: ReleaseLine.dev,
          version: '1.0.0',
          channel: 'dev',
          commit: 'fixture',
          pubspecVersion: '1.0.0+1',
          description: 'Fixture',
          outputDirectory: temp.path,
        );
        final binary = context.linuxBinaryName;
        final source = Directory(p.join(temp.path, binary))..createSync();
        final executable = File(p.join(source.path, binary))
          ..writeAsStringSync('fixture executable bytes');
        final data = File(p.join(source.path, 'data.txt'))
          ..writeAsStringSync('fixture data bytes');
        final desktop = File(p.join(temp.path, '$binary.desktop'))
          ..writeAsStringSync('[Desktop Entry]\nName=Fixture\n');
        final icon = File(p.join(temp.path, '$binary.png'))
          ..writeAsStringSync('fixture icon bytes');
        for (final file in [data, desktop, icon]) {
          final chmod = await Process.run('chmod', ['0600', file.path]);
          expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
        }
        final chmod = await Process.run('chmod', ['0700', executable.path]);
        expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
        await normalizePermissions(source.path).run(verbose: false);

        final destination = p.join(temp.path, 'installed');
        final spec = rpmSpec(context, {'package_name': 'fixture'});
        final install = spec
            .split('\n%install\n')
            .last
            .split('\n%post\n')
            .first;
        final script = install
            .replaceAll('%{buildroot}', destination)
            .replaceAll('%{_bindir}', '/usr/bin')
            .replaceAll('%{_datadir}', '/usr/share')
            .replaceAll('%{name}', 'fixture');
        final result = await Process.run('sh', [
          '-ec',
          'umask $mask\n$script',
        ], workingDirectory: temp.path);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final installedDesktop = File(
          p.join(destination, 'usr/share/applications/fixture.desktop'),
        );
        expect(
          installedDesktop.statSync().mode & 0x1ff,
          0x1a4,
          reason: 'the desktop entry must remain readable to every user',
        );

        for (final entity in Directory(
          destination,
        ).listSync(recursive: true, followLinks: false)) {
          if (entity is Link) continue;
          final mode = entity.statSync().mode & 0x1ff;
          final isExecutable =
              entity is Directory ||
              entity.path == p.join(destination, 'usr/share/fixture', binary);
          expect(
            mode,
            isExecutable ? 0x1ed : 0x1a4,
            reason: '${entity.path} must have a distributable mode',
          );
        }
        expect(
          File(
            p.join(destination, 'usr/share/fixture', binary),
          ).readAsBytesSync(),
          executable.readAsBytesSync(),
        );
        expect(
          File(
            p.join(destination, 'usr/share/fixture/data.txt'),
          ).readAsBytesSync(),
          data.readAsBytesSync(),
        );
        expect(
          Link(p.join(destination, 'usr/bin/fixture')).targetSync(),
          '/usr/share/fixture/$binary',
        );
      },
      skip: !Platform.isLinux,
    );
  }
}
