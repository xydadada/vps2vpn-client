import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:fl_clash/common/constant.dart'
    show defaultPrimaryColor, trafficSampleLength;
import 'package:fl_clash/common/dialog.dart' show dialogs;
import 'package:fl_clash/common/fixed.dart' show FixedList;
import 'package:fl_clash/models/models.dart' show SubscriptionInfo, Traffic;
import 'package:prism_ui/banner.dart' show BannerLevel;
import 'package:prism_ui/navigator.dart' show rootNavigatorKey;
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/devices.dart';
import 'package:fl_clash/vps2vpn/feedback.dart';
import 'package:fl_clash/vps2vpn/home.dart' show mainGroup;
import 'package:fl_clash/vps2vpn/mine.dart' show vpsThemeColors;
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:fl_clash/vps2vpn/shell.dart';
import 'package:fl_clash/vps2vpn/takeover.dart'
    show VpsTakeoverReport, vpsTakeoverReport;
import 'package:fl_clash/vps2vpn/takeover_notice.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart';
import 'package:prism_ui/prism_ui.dart' show ThemeMode;
import 'package:rust_api/window.dart';

/// Test hook for CI: with VPS2VPN_SHOT_DIR set, vps2vpn photographs every page
/// in each theme, language and window size into that folder, before and after
/// connecting, then quits. VPS2VPN_SHOT_SUB (loopback only) is the
/// subscription it imports after the empty first screen; legend.yaml beside
/// it is a third-party panel's, shot last.
final String? _shotDir = Platform.environment['VPS2VPN_SHOT_DIR'];

final _boundary = GlobalKey();

Widget vpsShotBoundary(Widget child) =>
    _shotDir == null ? child : RepaintBoundary(key: _boundary, child: child);

const _sizes = {
  'default': ui.Size(680, 580),
  'min': ui.Size(380, 400),
  'wide': ui.Size(1100, 720),
};
const _zh = ['zh'];
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
  final _holds = <ProviderSubscription<Object?>>[];

  Future<void> run() async {
    try {
      await dir.create(recursive: true);
      await _settle(4000);
      await _round('empty', tabs: const [vpsTabHome], sizes: const ['default']);
      await _round('audit-empty', tabs: _tabs.keys.toList(), locales: _zh);

      final sub = vpsLoopbackLink(Platform.environment['VPS2VPN_SHOT_SUB']);
      if (sub != null && container.read(profilesProvider).isEmpty) {
        await container
            .read(profilesActionProvider.notifier)
            .addProfileFromLink(sub);
      }
      await _until(() => container.read(profilesProvider).isNotEmpty, 60);
      await _settle(5000);
      await _round('ready', tabs: const [vpsTabHome]);
      await _round('audit-ready', tabs: _tabs.keys.toList(), locales: _zh);

      await _keyframes('connect');
      await _until(() => container.read(isStartProvider), 60);
      _holdSpeed();
      await _settle(15000);
      await _breath();
      await _round('connected', tabs: _tabs.keys.toList());
      await _scaled();
      await _alert('connected');
      await _pages('audit-connected');
      await _loading();
      await _dialogs();
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
      if (sub != null) {
        await _legend(sub.replaceFirst('sub.yaml', 'legend.yaml'));
      }

      _releaseSpeed();
      await _keyframes('disconnect');
      await _until(() => !container.read(isStartProvider), 30);
    } catch (e, s) {
      _log.writeln('failed: $e\n$s');
    } finally {
      _releaseSpeed();
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

  /// Long pages a screen at a time, top to bottom.
  Future<void> _pages(String state) async {
    _locale('zh');
    for (final size in const ['default', 'wide']) {
      await desktopWindow.setSize(_sizes[size]!);
      await _settle(800);
      for (final theme in const [ThemeMode.light, ThemeMode.dark]) {
        _theme(theme);
        for (final tab in _tabs.keys) {
          vpsTab.value = tab;
          await _settle(1200);
          final scroll = _scroller();
          if (scroll == null) continue;
          final end = scroll.position.maxScrollExtent;
          final step = scroll.position.viewportDimension * 0.85;
          for (var i = 0; ; i++) {
            final at = math.min(step * i, end);
            scroll.position.jumpTo(at);
            await _settle(500);
            await _shoot(
              '$state-${_tabs[tab]}-$size-${theme.name}-zh-p${i + 1}',
            );
            if (at >= end) break;
          }
          scroll.position.jumpTo(0);
        }
      }
    }
  }

  BuildContext? _find(String type) {
    BuildContext? found;
    void visit(Element e) {
      if (found != null) return;
      if (e.widget.runtimeType.toString() == type) {
        found = e;
        return;
      }
      e.visitChildren(visit);
    }

    _boundary.currentContext?.visitChildElements(visit);
    return found;
  }

  ScrollableState? _scroller() {
    ScrollableState? best;
    void visit(Element e) {
      if (e is StatefulElement && e.state is ScrollableState) {
        final s = e.state as ScrollableState;
        final p = s.position;
        if (p.axis == Axis.vertical &&
            p.hasContentDimensions &&
            p.maxScrollExtent > (best?.position.maxScrollExtent ?? 0)) {
          best = s;
        }
      }
      e.visitChildren(visit);
    }

    _boundary.currentContext?.visitChildElements(visit);
    return best;
  }

  Future<void> _loading() async {
    await desktopWindow.setSize(_sizes['default']!);
    _locale('zh');
    for (final theme in const [ThemeMode.light, ThemeMode.dark]) {
      _theme(theme);
      for (final tab in const [vpsTabServers, vpsTabCheck, vpsTabClaude]) {
        vpsTab.value = vpsTabHome;
        await _settle(1500);
        vpsTab.value = tab;
        await _settle(500);
        await _shoot('audit-loading-${_tabs[tab]}-default-${theme.name}-zh');
      }
    }
  }

  Future<void> _dialogs() async {
    _locale('zh');
    for (final size in const ['default', 'wide']) {
      await desktopWindow.setSize(_sizes[size]!);
      for (final theme in const [ThemeMode.light, ThemeMode.dark]) {
        _theme(theme);
        vpsTab.value = vpsTabHome;
        await _settle(1200);
        final tag = '$size-${theme.name}-zh';
        Future<void> shot(String name, Future<Object?> Function() open) async {
          unawaited(open());
          await _settle(1800);
          await _shoot('audit-dialog-$name-$tag');
        }

        Future<void> close() async {
          rootNavigatorKey.currentState?.pop();
          await _settle(800);
        }

        BuildContext here() => rootNavigatorKey.currentContext!;
        await shot(
          'takeover',
          () => vpsShowTakeoverAsk(const ['Clash Verge', 'FlClash']),
        );
        await close();
        await shot('feedback', vpsShowFeedback);
        await close();
        await shot('devices', vpsShowDevices);
        await close();
        await shot('kick', () => vpsShowDevices(confirmKick: true));
        await close();
        await shot('remove-subscription', () => vpsAskRemoveProfile(here()));
        await close();
        await shot(
          'whats-new',
          () => dialogs.showMessage(
            title: '1.0.33 更新内容',
            message: const TextSpan(
              text: '首页标题在智能线路切换时不再来回跳；导航栏、标题栏和侧边栏的细节修整。',
            ),
          ),
        );
        await close();
        dialogs.showBanner(
          '订阅内容读不懂，可能链接不完整或服务器返回了错误页面。请向管理员确认链接。',
          level: BannerLevel.error,
        );
        await _settle(1200);
        await _shoot('audit-banner-error-$tag');
        dialogs.showBanner(vpsRemovedText(here()));
        await _settle(1200);
        await _shoot('audit-banner-removed-$tag');
        await _settle(6000);
      }
    }
  }

  /// Terabytes left, most of a year to go, a 5x node picked by hand.
  Future<void> _legend(String link) async {
    final before = container.read(profilesProvider).length;
    await container
        .read(profilesActionProvider.notifier)
        .addProfileFromLink(link);
    await _until(() => container.read(profilesProvider).length > before, 60);
    final profile = container.read(currentProfileProvider);
    if (profile == null) return;
    const tb = 1024 * 1024 * 1024 * 1024;
    final expire = DateTime.now().add(const Duration(days: 328));
    container
        .read(profilesActionProvider.notifier)
        .putProfile(
          profile.copyWith(
            subscriptionInfo: SubscriptionInfo(
              upload: (0.4 * tb).round(),
              download: (8.7 * tb).round(),
              total: 100 * tb,
              expire: expire.millisecondsSinceEpoch ~/ 1000,
            ),
          ),
          select: true,
        );
    await _settle(15000);
    final main = mainGroup(container.read(currentGroupsStateProvider).value);
    const dear = 'us 洛杉矶 · 5.0x';
    if (main != null && main.all.any((p) => p.name == dear)) {
      await container
          .read(proxiesActionProvider.notifier)
          .changeProxy(groupName: main.name, proxyName: dear);
    }
    vpsTakeoverReport.value = const VpsTakeoverReport(closed: ['FlClash']);
    await _settle(8000);
    await _round(
      'legend',
      tabs: const [vpsTabHome, vpsTabServers, vpsTabMe],
      sizes: const ['wide', 'default'],
    );
    // The default window shows the tiles only once scrolled to them.
    await desktopWindow.setSize(_sizes['default']!);
    vpsTab.value = vpsTabHome;
    for (final theme in const [ThemeMode.light, ThemeMode.dark]) {
      _theme(theme);
      for (final locale in const ['zh', 'en']) {
        _locale(locale);
        await _settle(1200);
        final tiles = _find('_Stats');
        if (tiles != null && tiles.mounted) {
          await Scrollable.ensureVisible(tiles, alignment: 0.3);
        }
        await _settle(500);
        await _shoot('legend-home-default-${theme.name}-$locale-tiles');
        _scroller()?.position.jumpTo(0);
      }
    }
  }

  /// CI idles at 0 B/s: a still minute of browsing, about 14.7 KB/s.
  void _holdSpeed() {
    final rand = math.Random(7);
    const bursts = {
      14: 1.5,
      15: 2.6,
      16: 1.7,
      33: 1.9,
      34: 1.4,
      49: 1.4,
      50: 2.3,
      51: 2.9,
      52: 1.8,
      53: 1.3,
    };
    final samples = [
      for (var i = 0; i < trafficSampleLength - 1; i++)
        Traffic(
          down: ((11 + rand.nextDouble() * 7) * 1024 * (bursts[i] ?? 1))
              .round(),
          up: ((1.2 + rand.nextDouble() * 1.2) * 1024).round(),
        ),
      const Traffic(down: 15053, up: 1946),
    ];
    const total = Traffic(down: 1288490189, up: 42991616);
    final speed = container.read(trafficsProvider.notifier);
    final sum = container.read(totalTrafficProvider.notifier);
    void hold() =>
        speed.value = FixedList(trafficSampleLength, list: [...samples]);
    hold();
    sum.value = total;
    _holds
      ..add(
        container.listen<FixedList<Traffic>>(trafficsProvider, (_, next) {
          final list = next.list;
          if (list.length != samples.length || list.last != samples.last) {
            hold();
          }
        }),
      )
      ..add(
        container.listen<Traffic>(totalTrafficProvider, (_, next) {
          if (next != total) sum.value = total;
        }),
      );
  }

  void _releaseSpeed() {
    for (final hold in _holds) {
      hold.close();
    }
    _holds.clear();
  }

  void _locale(String locale) => container
      .read(appSettingProvider.notifier)
      .update((s) => s.copyWith(locale: locale));

  void _theme(ThemeMode theme) => container
      .read(themeSettingProvider.notifier)
      .update((s) => s.copyWith(themeMode: theme));

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
