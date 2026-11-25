// vps2vpn simple/advanced switches and plain-word labels. No widgets here:
// lib/common reads these, and the common barrel must not reach the UI.

import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/enum/enum.dart';

/// Mirrors AppSettingProps.advancedMode for label getters that have no ref.
/// Set by the navigation provider, which every page watches.
bool vps2vpnAdvancedMode = false;

/// True only under FlClash's own test suite (test/flutter_test_config.dart):
/// every place that picks simple or advanced UI then shows FlClash's, so
/// upstream tests keep testing upstream pages. Never set in the app.
bool vps2vpnUpstreamUi = false;

/// Simple mode offers only "smart routing" and "proxy everything".
List<Mode> visibleModes(bool advancedMode) =>
    advancedMode ? Mode.values : const [Mode.rule, Mode.global];

/// Plain-word page titles in simple mode; null keeps FlClash's own.
String? simplePageLabel(PageLabel label) {
  if (vps2vpnAdvancedMode || vps2vpnUpstreamUi) return null;
  final l = currentAppLocalizations;
  return switch (label) {
    PageLabel.dashboard => l.vHome,
    PageLabel.proxies => l.vServers,
    PageLabel.profiles => l.vSubscriptions,
    PageLabel.tools => l.vMine,
    _ => null,
  };
}

/// Plain-word routing names in simple mode; null keeps FlClash's own.
String? simpleModeLabel(Mode mode) {
  if (vps2vpnAdvancedMode || vps2vpnUpstreamUi) return null;
  final l = currentAppLocalizations;
  return switch (mode) {
    Mode.rule => l.vSmartRouting,
    Mode.global => l.vProxyAll,
    Mode.direct => null,
  };
}

/// The dashboard cards simple mode shows, in this order.
const simpleDashboardWidgets = [
  DashboardWidget.currentOutbound,
  DashboardWidget.networkSpeed,
  DashboardWidget.outboundMode,
  DashboardWidget.vpnButton,
  DashboardWidget.networkTakeover,
  DashboardWidget.profiles,
];

/// The core's smart groups (core/vps2vpn_smart.go) under plain names.
const vpsSmartGroupName = '⚡ 智能线路';
const vpsCheapGroupName = '⚡ 低倍率线路';
const vpsDearGroupName = '⚡ 高倍率线路';
const vpsAIGroupName = '🤖 AI 专线';
