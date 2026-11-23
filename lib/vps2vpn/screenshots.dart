import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:fl_clash/vps2vpn/shell.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart';
import 'package:prism_ui/prism_ui.dart' show ThemeMode;
import 'package:rust_api/window.dart';

/// Test hook for CI: with VPS2VPN_SHOT_DIR set, vps2vpn photographs every page
/// in each theme, language and window size into that folder, before and after
/// connecting, then quits. VPS2VPN_SHOT_SUB (loopback only) is the
/// subscription it imports after the empty first screen.
final String? vpsShotDir = Platform.environment['VPS2VPN_SHOT_DIR'];

final _boundary = GlobalKey();

Widget vpsShotBoundary(Widget child) =>
    vpsShotDir == null ? child : RepaintBoundary(key: _boundary, child: child);

const _sizes = {
  'default': ui.Size(680, 580),
  'min': ui.Size(380, 400),
  'wide': ui.Size(1100, 720),
};
const _tabs = {
  vpsTabHome: 'home',
  vpsTabServers: 'nodes',
  vpsTabCheck: 'check',
  vpsTabMe: 'settings',
};

bool _started = false;

void vpsStartShots(ProviderContainer container) {
  final dir = vpsShotDir;
  if (dir == null || _started) return;
  _started = true;
  unawaited(_ShotRun(container, Directory(dir)).run());
}

class _ShotRun {
  _ShotRun(this.container, this.dir);

  final ProviderContainer container;
  final Directory dir;
  final _log = StringBuffer();

  Future<void> run() async {
    try {
      await dir.create(recursive: true);
      await _settle(4000);
      await _round('empty', tabs: const [vpsTabHome], sizes: const ['default']);

      final sub = vpsLoopbackLink(Platform.environment['VPS2VPN_SHOT_SUB']);
      if (sub != null && container.read(profilesProvider).isEmpty) {
        await container
            .read(profilesActionProvider.notifier)
            .addProfileFromLink(sub);
      }
      await _until(() => container.read(profilesProvider).isNotEmpty, 60);
      await _settle(5000);
      await _round('ready', tabs: const [vpsTabHome]);

      container.read(commonActionProvider.notifier).toggleRunning();
      await _until(() => container.read(isStartProvider), 60);
      await _settle(15000);
      await _round('connected', tabs: _tabs.keys.toList());

      container.read(commonActionProvider.notifier).toggleRunning();
      await _until(() => !container.read(isStartProvider), 30);
    } catch (e, s) {
      _log.writeln('failed: $e\n$s');
    } finally {
      await File(join(dir.path, 'shots.log')).writeAsString(_log.toString());
      await container.read(systemActionProvider.notifier).handleExit(false);
    }
  }

  Future<void> _round(
    String state, {
    required List<int> tabs,
    List<String> sizes = const ['default', 'min', 'wide'],
  }) async {
    for (final size in sizes) {
      await desktopWindow.setSize(_sizes[size]!);
      await _settle(800);
      for (final theme in const [ThemeMode.light, ThemeMode.dark]) {
        container
            .read(themeSettingProvider.notifier)
            .update((s) => s.copyWith(themeMode: theme));
        for (final locale in const ['zh', 'en']) {
          container
              .read(appSettingProvider.notifier)
              .update((s) => s.copyWith(locale: locale));
          for (final tab in tabs) {
            vpsTab.value = tab;
            await _settle(1200);
            await _shoot('$state-${_tabs[tab]}-$size-${theme.name}-$locale');
          }
        }
      }
    }
  }

  Future<void> _shoot(String name) async {
    final object = _boundary.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary) {
      _log.writeln('$name: nothing to photograph');
      return;
    }
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final image = await object.toImage(pixelRatio: view.devicePixelRatio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (png == null) return;
    await File(
      join(dir.path, '$name.png'),
    ).writeAsBytes(png.buffer.asUint8List());
    _log.writeln(
      '$name ${object.size.width.round()}x${object.size.height.round()}',
    );
  }

  Future<void> _settle(int ms) async {
    await Future<void>.delayed(Duration(milliseconds: ms));
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _until(bool Function() done, int seconds) async {
    for (var i = 0; i < seconds * 2 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    _log.writeln('waited: ${done() ? 'ok' : 'timed out'}');
  }
}
