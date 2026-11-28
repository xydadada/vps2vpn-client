import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/vps2vpn/update_integrity.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class UpdateInstaller {
  const UpdateInstaller();

  bool get isAndroid => system.isAndroid;

  Future<bool> verify(String path) => vpsVerifyInstaller(path);

  Future<int?> installPackage(String path) async => app?.installPackage(path);

  bool? runWindows(String path) =>
      windows?.runas(path, windowsUpdateArguments(pid));
}

final updateInstallerProvider = Provider<UpdateInstaller>(
  (ref) => const UpdateInstaller(),
);
