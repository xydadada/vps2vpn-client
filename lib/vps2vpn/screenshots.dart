import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/common/constant.dart' show defaultPrimaryColor;
import 'package:fl_clash/common/dialog.dart' show dialogs;
import 'package:prism_ui/navigator.dart' show rootNavigatorKey;
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/mine.dart' show vpsThemeColors;
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
final String? _shotDir = Platform.environment['VPS2VPN_SHOT_DIR'];

final _boundary = GlobalKey();

Widget vpsShotBoundary(Widget child) =>
    _shotDir == null ? child : RepaintBoundary(key: _boundary, child: child);

const _sizes = {
  'default': ui.Size(680, 580),
  'min': ui.Size(380, 400),
  'wide': ui.Size(1100, 720),
};
const _tabs = {
  vpsTabHome: 'home',
  vpsTabServers: 'nodes',
  vpsTabCheck: 'check',
  vpsTabClaude: 'claude',
  vpsTabMe: 'settings',
};

bool _started = false;

void vpsStartShots(ProviderContainer container) {
  final dir = _shotDir;
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

      await _keyframes('connect');
      await _until(() => container.read(isStartProvider), 60);
      await _settle(15000);
      await _breath();
      await _round('connected', tabs: _tabs.keys.toList());
      await _scaled();
      await _alert('connected');
      for (final (color, _, en) in vpsThemeColors.skip(1)) {
        container
            .read(themeSettingProvider.notifier)
            .update((s) => s.copyWith(primaryColor: color));
        await _round(
          'accent-${en.split(' ').first.toLowerCase()}',
          tabs: const [vpsTabHome, vpsTabServers, vpsTabMe],
          sizes: const ['default'],
          locales: const ['zh'],
        );
        await _alert('accent-${en.split(' ').first.toLowerCase()}');
      }
      container
          .read(themeSettingProvider.notifier)
          .update((s) => s.copyWith(primaryColor: defaultPrimaryColor));

      await _keyframes('disconnect');
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
    List<String> locales = const ['zh', 'en'],
  }) async {
    for (final size in sizes) {
      await desktopWindow.setSize(_sizes[size]!);
      await _settle(800);
      for (final theme in const [ThemeMode.light, ThemeMode.dark]) {
        container
            .read(themeSettingProvider.notifier)
            .update((s) => s.copyWith(themeMode: theme));
        for (final locale in locales) {
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

  /// Connecting or disconnecting, back to back at first, to review the motion.
  Future<void> _keyframes(String what) async {
    await _darkHome();
    container.read(commonActionProvider.notifier).toggleRunning();
    for (var i = 0; i < 24; i++) {
      await _settle(i < 12 ? 0 : 120);
      await _shoot('keyframe-$what$i-home-default-dark-zh');
    }
  }

  Future<void> _breath() async {
    await _darkHome();
    for (var i = 0; i < 8; i++) {
      await _shoot('keyframe-breath$i-home-default-dark-zh');
      await _settle(500);
    }
  }

  Future<void> _darkHome() async {
    await desktopWindow.setSize(_sizes['default']!);
    vpsTab.value = vpsTabHome;
    container
        .read(appSettingProvider.notifier)
        .update((s) => s.copyWith(locale: 'zh'));
    container
        .read(themeSettingProvider.notifier)
        .update((s) => s.copyWith(themeMode: ThemeMode.dark));
    await _settle(1200);
  }

  /// Windows display scaling: the same scene rasterised at 125% and 150%,
  /// where a tile drawn in logical pixels could beat against the pixel grid.
  Future<void> _scaled() async {
    vpsTab.value = vpsTabHome;
    container
        .read(appSettingProvider.notifier)
        .update((s) => s.copyWith(locale: 'zh'));
    for (final size in const ['default', 'wide']) {
      await desktopWindow.setSize(_sizes[size]!);
      await _settle(800);
      for (final theme in const [ThemeMode.light, ThemeMode.dark]) {
        container
            .read(themeSettingProvider.notifier)
            .update((s) => s.copyWith(themeMode: theme));
        await _settle(1200);
        for (final (ratio, tag) in const [(1.25, '125'), (1.5, '150')]) {
          await _shoot(
            'scaled$tag-home-$size-${theme.name}-zh',
            pixelRatio: ratio,
          );
        }
      }
    }
  }

  Future<void> _alert(String state) async {
    await desktopWindow.setSize(_sizes['default']!);
    vpsTab.value = vpsTabHome;
    container
        .read(appSettingProvider.notifier)
        .update((s) => s.copyWith(locale: 'zh'));
    for (final theme in const [ThemeMode.light, ThemeMode.dark]) {
      container
          .read(themeSettingProvider.notifier)
          .update((s) => s.copyWith(themeMode: theme));
      await _settle(800);
      unawaited(
        dialogs.showMessage(
          title: '删除订阅',
          message: const TextSpan(text: '删除后需要重新导入订阅链接才能连接。'),
          confirmText: '删除',
        ),
      );
      await _settle(1500);
      await _shoot('$state-alert-default-${theme.name}-zh');
      rootNavigatorKey.currentState?.pop();
      await _settle(800);
    }
  }

  Future<void> _shoot(String name, {double? pixelRatio}) async {
    final object = _boundary.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary) {
      _log.writeln('$name: nothing to photograph');
      return;
    }
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final image = await object.toImage(
      pixelRatio: (pixelRatio ?? 1) * view.devicePixelRatio,
    );
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
