import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/common/provider_reader.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/flags.dart';
import 'package:fl_clash/vps2vpn/home.dart' show mainGroup;
import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:rust_api/tray.dart';

/// Whole system (virtual adapter) or the system proxy: exactly one of them.
void vpsUseWholeSystem(ProviderReader read, bool whole) {
  read(
    patchClashConfigProvider.notifier,
  ).update((s) => s.copyWith.tun(enable: whole));
  read(
    networkSettingProvider.notifier,
  ).update((s) => s.copyWith(systemProxy: !whole));
}

/// The tray menu in simple mode, in the app's own words: where things stand,
/// Connect or Disconnect, the two routing modes and the two ways to take
/// over. Null in advanced mode, which keeps the full menu.
List<TrayMenuItem>? vpsTrayMenu({
  required TrayState state,
  required ProviderReader read,
  required VoidCallback onShow,
  required VoidCallback onExit,
}) {
  if (vps2vpnAdvancedMode || vps2vpnUpstreamUi) return null;
  final zh = currentAppLocalizations.localeName.startsWith('zh');
  String say(String cn, String en) => zh ? cn : en;
  final group = mainGroup(state.groups);
  final picked = group == null
      ? null
      : state.selectedMap[group.name] ?? group.now;
  final line = switch (picked) {
    null || '' => null,
    vpsSmartGroupName => say('智能线路', 'Smart line'),
    vpsAIGroupName => say('AI 专线', 'AI line'),
    final name => name,
  };
  final status = !state.isStart
      ? say('未连接', 'Not connected')
      : state.suspended
      ? say('已暂停', 'Paused')
      : say('已连接', 'Connected');
  return [
    TrayMenuAction(
      label: state.isStart && line != null ? '$status · $line' : status,
      enabled: false,
    ),
    const TrayMenuSeparator(),
    TrayMenuAction(
      label: state.isStart ? say('断开', 'Disconnect') : say('连接', 'Connect'),
      onSelected: () => read(commonActionProvider.notifier).toggleRunning(),
    ),
    const TrayMenuSeparator(),
    TrayMenuCheckbox(
      label: say('规则模式', 'Rule mode'),
      checked: state.mode != Mode.global,
      onSelected: () =>
          read(setupActionProvider.notifier).changeMode(Mode.rule),
    ),
    TrayMenuCheckbox(
      label: say('全局模式', 'Global mode'),
      checked: state.mode == Mode.global,
      onSelected: () =>
          read(setupActionProvider.notifier).changeMode(Mode.global),
    ),
    const TrayMenuSeparator(),
    TrayMenuCheckbox(
      label: say('系统代理', 'System proxy'),
      checked: !state.tunEnable,
      onSelected: () => vpsUseWholeSystem(read, false),
    ),
    TrayMenuCheckbox(
      label: say('虚拟网卡', 'TUN'),
      checked: state.tunEnable,
      onSelected: () => vpsUseWholeSystem(read, true),
    ),
    const TrayMenuSeparator(),
    TrayMenuAction(
      label: say('打开 vps2vpn', 'Open vps2vpn'),
      onSelected: onShow,
    ),
    TrayMenuAction(label: say('退出', 'Quit'), onSelected: onExit),
  ];
}

/// The tray's hover text: the app's name and whether it is connected.
String vpsTrayTip(TrayState state, String appName) {
  if (vps2vpnAdvancedMode || vps2vpnUpstreamUi) return appName;
  final zh = currentAppLocalizations.localeName.startsWith('zh');
  final status = !state.isStart
      ? (zh ? '未连接' : 'Not connected')
      : state.suspended
      ? (zh ? '已暂停' : 'Paused')
      : (zh ? '已连接' : 'Connected');
  return '$appName · $status';
}
