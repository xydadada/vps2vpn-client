// vps2vpn simple-mode window: our own sidebar (wide) or floating tab bar
// (narrow) around four pages. Replaces FlClash's shell while advanced mode
// is off.

import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/account.dart';
import 'package:fl_clash/vps2vpn/claude_check.dart';
import 'package:fl_clash/vps2vpn/check.dart';
import 'package:fl_clash/vps2vpn/home.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/local_network.dart';
import 'package:fl_clash/vps2vpn/mine.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:fl_clash/vps2vpn/servers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' show Theme;

/// The open tab; pages switch it (e.g. the home button opens "Me").
/// VPS2VPN_TAB (0-4) opens a page at start; used for test screenshots.
final vpsTab = ValueNotifier<int>(
  (int.tryParse(Platform.environment['VPS2VPN_TAB'] ?? '') ?? 0).clamp(0, 4),
);

const vpsTabHome = 0;
const vpsTabServers = 1;
const vpsTabCheck = 2;
const vpsTabClaude = 3;
const vpsTabMe = 4;

class VpsShell extends StatelessWidget {
  const VpsShell({super.key});

  /// Ctrl+1 to Ctrl+5 (⌘ on macOS) open the pages in the sidebar's order.
  static final _shortcuts = <ShortcutActivator, VoidCallback>{
    for (final (i, key) in const [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
    ].indexed) ...{
      SingleActivator(key, control: true): () => vpsTab.value = i,
      SingleActivator(key, meta: true): () => vpsTab.value = i,
    },
  };

  static const _pages = [
    VpsHomePage(),
    VpsServersPage(),
    VpsCheckPage(),
    VpsClaudePage(),
    VpsMePage(),
  ];

  @override
  Widget build(BuildContext context) {
    // Our pages sit outside prism_ui's Scaffold, so give them the app's font
    // (and no debug underline) here.
    final page = DefaultTextStyle(
      style: Theme.of(context).bodyTextStyle.copyWith(
        decoration: TextDecoration.none,
        color: VpsPalette.of(context).text,
        fontFamily: vpsFont,
        fontFamilyFallback: vpsFontFallback,
      ),
      child: VpsBackdrop(
        // Pages and the tab bar keep clear of Android's system bars.
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth >= 760;
              return ValueListenableBuilder<int>(
                valueListenable: vpsTab,
                builder: (context, tab, _) {
                  final body = AnimatedSwitcher(
                    duration: VpsMotion.medium,
                    switchInCurve: VpsMotion.settle,
                    // Pages fill the area and start at the top, short or long.
                    layoutBuilder: (current, previous) => Stack(
                      fit: StackFit.expand,
                      children: [...previous, ?current],
                    ),
                    transitionBuilder: (child, a) => FadeTransition(
                      opacity: a,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0, 0.015),
                          end: Offset.zero,
                        ).animate(a),
                        child: child,
                      ),
                    ),
                    child: KeyedSubtree(key: ValueKey(tab), child: _pages[tab]),
                  );
                  if (wide) {
                    return Row(
                      children: [
                        _SideNav(tab: tab),
                        Expanded(child: body),
                      ],
                    );
                  }
                  return Stack(
                    children: [
                      Positioned.fill(child: body),
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 16,
                        child: _BottomNav(tab: tab),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Focus(autofocus: true, skipTraversal: true, child: page),
    );
  }
}

List<(VpsIcon, String)> _tabs(BuildContext context) => [
  (VpsIcon.home, tr(context, '概览', 'Overview')),
  (VpsIcon.servers, tr(context, '节点', 'Nodes')),
  (VpsIcon.check, tr(context, '检测', 'Check')),
  (VpsIcon.sparkle, 'Claude'),
  (VpsIcon.me, tr(context, '设置', 'Settings')),
];

class _SideNav extends ConsumerWidget {
  const _SideNav({required this.tab});

  final int tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = VpsPalette.of(context);
    // Frosted glass, like the macOS sidebar: the state's light behind the
    // window shows through, blurred, so the sidebar sits above the content
    // instead of being a grey slab beside it.
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
        child: Container(
          width: 224,
          decoration: BoxDecoration(
            color: p.side.withValues(alpha: p.dark ? 0.62 : 0.70),
            border: Border(right: BorderSide(color: p.line)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 22, 16, 18),
          child: _sideColumn(context, p),
        ),
      ),
    );
  }

  Widget _sideColumn(BuildContext context, VpsPalette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Row(
            children: [
              const VpsLogo(size: 30),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'vps2vpn',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: vpsText(
                        p,
                        type: VpsType.headline,
                        weight: FontWeight.w600,
                        spacing: 0.2,
                      ),
                    ),
                    Text(
                      tr(context, '私有网络', 'Private network'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: vpsText(p, type: VpsType.caption, color: p.soft),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 30),
        for (final (i, (icon, label)) in _tabs(context).indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _NavItem(
              icon: icon,
              label: label,
              selected: i == tab,
              onTap: () => vpsTab.value = i,
            ),
          ),
        const Spacer(),
        const _SideStatus(),
      ],
    );
  }
}

/// Bottom of the sidebar: connection state, the line in use and live speed.
/// Tapping it opens the overview.
class _SideStatus extends ConsumerWidget {
  const _SideStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = VpsPalette.of(context);
    final isStart = ref.watch(isStartProvider);
    final suspended = isStart && ref.watch(suspendProvider);
    final on = isStart && !suspended;
    final hasProfile = ref.watch(profilesProvider.select((s) => s.isNotEmpty));
    final group = mainGroup(ref.watch(currentGroupsStateProvider).value);
    final line = group == null
        ? null
        : ref.watch(selectedProxyNameProvider(group.name));
    final now = on
        ? ref.watch(trafficsProvider).list.safeLast(const Traffic())
        : const Traffic();
    // Same order as the overview: a refused account or a silent line is not
    // "connected", whatever the Core says.
    final block = vpsAccountBlock(ref.watch(vpsMemberProvider).value);
    final delay = group == null || !on
        ? null
        : ref.watch(
            delayProvider(proxyName: group.name, testUrl: group.testUrl),
          );
    final lineDown = on && delay != null && delay < 0;
    final localNet = lineDown ? ref.watch(vpsLocalNetProvider).value : null;
    final (title, dotColor) = !hasProfile
        ? (tr(context, '未导入订阅', 'No subscription'), p.muted)
        : block != null
        ? (vpsAccountBlockReason(context, block), p.bad)
        : suspended
        ? (tr(context, '已暂停', 'Paused'), p.warn)
        : localNet == VpsLocalNet.offline
        ? (tr(context, '本机没有联网', 'This computer is offline'), p.warn)
        : localNet == VpsLocalNet.portal
        ? (tr(context, '网络需要先登录', 'This network wants a login'), p.warn)
        : lineDown
        ? (tr(context, '线路无响应', 'Line not responding'), p.warn)
        : on
        ? (tr(context, '已连接', 'Connected'), p.good)
        : (tr(context, '未连接', 'Not connected'), p.muted);
    final glow = dotColor == p.good;
    final small = vpsText(
      p,
      type: VpsType.caption,
      color: p.soft,
      tabular: true,
    );
    return VpsPressable(
      onTap: () => vpsTab.value = vpsTabHome,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        decoration: ShapeDecoration(
          color: p.card,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(VpsRadius.medium),
            side: BorderSide(color: p.line),
          ),
          shadows: p.raise,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AnimatedContainer(
                  duration: VpsMotion.medium,
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dotColor,
                    boxShadow: glow
                        ? [
                            BoxShadow(
                              color: p.good.withValues(alpha: 0.55),
                              blurRadius: 8,
                            ),
                          ]
                        : const [],
                  ),
                ),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: vpsText(
                      p,
                      type: VpsType.subhead,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (hasProfile && line != null) ...[
              const SizedBox(height: 6),
              Text(
                friendlyLineName(context, line),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: vpsText(p, type: VpsType.footnote, color: p.soft),
              ),
            ],
            AnimatedSize(
              duration: VpsMotion.medium,
              curve: VpsMotion.settle,
              alignment: Alignment.topLeft,
              child: on
                  ? Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Container(
                        padding: const EdgeInsets.only(top: 10),
                        decoration: BoxDecoration(
                          border: Border(top: BorderSide(color: p.line)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '↓ ${now.down.traffic.show}/s',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: small,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                '↑ ${now.up.traffic.show}/s',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: small,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final VpsIcon icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    return VpsPressable(
      onTap: onTap,
      selected: selected,
      child: AnimatedContainer(
        duration: VpsMotion.medium,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: ShapeDecoration(
          color: selected ? p.selected : const Color(0x00000000),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(VpsRadius.small),
          ),
        ),
        child: Row(
          children: [
            VpsIconView(icon, size: 18, color: selected ? p.accent : p.muted),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: vpsText(
                  p,
                  type: VpsType.body,
                  weight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? p.text : p.soft,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.tab});

  final int tab;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(VpsRadius.large),
      side: BorderSide(color: p.line),
    );
    // Acrylic, as Fluent and iOS do for a bar floating over content: the
    // page scrolls by underneath, blurred.
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: [
          BoxShadow(
            color: const Color(0xFF000000).withValues(alpha: 0.22),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(VpsRadius.large),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            height: 66,
            padding: const EdgeInsets.all(6),
            decoration: ShapeDecoration(
              color: p.card.withValues(alpha: p.dark ? 0.72 : 0.78),
              shape: shape,
            ),
            child: _bar(context, p),
          ),
        ),
      ),
    );
  }

  Widget _bar(BuildContext context, VpsPalette p) {
    return Row(
      children: [
        for (final (i, (icon, label)) in _tabs(context).indexed)
          Expanded(
            child: VpsPressable(
              onTap: () => vpsTab.value = i,
              selected: i == tab,
              child: AnimatedContainer(
                duration: VpsMotion.medium,
                decoration: ShapeDecoration(
                  color: i == tab ? p.selected : const Color(0x00000000),
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(VpsRadius.large),
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    VpsIconView(
                      icon,
                      size: 21,
                      color: i == tab ? p.accent : p.muted,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      label,
                      style: vpsText(
                        p,
                        type: VpsType.caption,
                        weight: FontWeight.w600,
                        color: i == tab ? p.text : p.soft,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Page frame: big title, optional action, scrolling body with room for the
/// floating tab bar on narrow windows.
class VpsPage extends StatelessWidget {
  const VpsPage({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    required this.children,
  });

  final String title;
  final String? subtitle;
  final Widget? action;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 600;
        final side = wide ? 36.0 : 16.0;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            side,
            wide ? 30 : 18,
            side,
            // The shell floats its bottom bar below 760 window width.
            MediaQuery.sizeOf(context).width < 760 ? 100 : 36,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 940),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: vpsText(
                                p,
                                type: wide ? VpsType.largeTitle : VpsType.title,
                                weight: FontWeight.w600,
                                spacing: -0.7,
                              ),
                            ),
                            if (subtitle != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  subtitle!,
                                  style: vpsText(
                                    p,
                                    type: VpsType.body,
                                    color: p.soft,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      ?action,
                    ],
                  ),
                  const SizedBox(height: 22),
                  // Blocks arrive one after another, top to bottom.
                  for (final (i, child) in children.indexed)
                    VpsEnter(index: i, child: child),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
