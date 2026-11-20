// vps2vpn "Servers": pick the line you use, see how fast each one answers.

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/home.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/shell.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Protocol names a non-expert can read.
String protocolLabel(BuildContext context, String type) {
  final t = type.toLowerCase();
  return switch (t) {
    'hysteria2' => 'Hysteria2',
    'hysteria' => 'Hysteria',
    'vless' => 'VLESS',
    'tuic' => 'TUIC',
    'trojan' => 'Trojan',
    'vmess' => 'VMess',
    'ss' || 'shadowsocks' => 'Shadowsocks',
    'anytls' => 'AnyTLS',
    'wireguard' => 'WireGuard',
    'direct' => tr(context, '直连', 'Direct'),
    'reject' => tr(context, '拦截', 'Block'),
    'selector' => tr(context, '手动选择', 'Manual'),
    'urltest' => tr(context, '自动测速', 'URL test'),
    'fallback' => tr(context, '故障转移', 'Fallback'),
    'loadbalance' => tr(context, '负载均衡', 'Balanced'),
    _ => type,
  };
}

class VpsServersPage extends ConsumerStatefulWidget {
  const VpsServersPage({super.key});

  @override
  ConsumerState<VpsServersPage> createState() => _VpsServersPageState();
}

final _autoTested = <String>{};
int? _autoTestedProfile;

void _syncAutoTestProfile(WidgetRef ref) {
  final pid = ref.read(currentProfileProvider)?.id;
  if (_autoTestedProfile != pid) {
    _autoTestedProfile = pid;
    _autoTested.clear();
  }
}

void vpsAutoTestOnce(WidgetRef ref, Group group) {
  if (group.name.isEmpty || group.all.isEmpty) return;
  _syncAutoTestProfile(ref);
  if (_autoTested.contains(group.name)) return;
  final context = ref.context;
  final profileId = ref.read(currentProfileProvider)?.id;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // An abandoned frame must not reserve or release another owner's slot.
    if (!context.mounted ||
        ref.read(currentProfileProvider)?.id != profileId) {
      return;
    }
    _syncAutoTestProfile(ref);
    if (!_autoTested.add(group.name)) return;
    ref
        .read(proxiesActionProvider.notifier)
        .delayTest(group.all, group.testUrl);
  });
}

/// Remembered for the whole app session, like the selected tab.
final _byLatency = ValueNotifier<bool>(true);

/// Sort key: answered lines by latency, then untested, then timeouts.
int _rank(int? d) => switch (d) {
  null || 0 => 1 << 20,
  < 0 => 1 << 21,
  final v => v,
};

bool _isPinned(String name) =>
    name == vpsSmartGroupName || name == vpsAIGroupName;

class _VpsServersPageState extends ConsumerState<VpsServersPage> {
  String? _groupName;
  bool _testing = false;

  void _autoTest(Group group) {
    if (group.name.isEmpty || group.all.isEmpty) return;
    _syncAutoTestProfile(ref);
    if (_autoTested.contains(group.name)) return;
    final profileId = ref.read(currentProfileProvider)?.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ref.read(currentProfileProvider)?.id != profileId) {
        return;
      }
      _syncAutoTestProfile(ref);
      if (_autoTested.add(group.name)) {
        _test(group);
      }
    });
  }

  Future<void> _test(Group group) async {
    if (_testing) return;
    setState(() => _testing = true);
    try {
      await ref
          .read(proxiesActionProvider.notifier)
          .delayTest(group.all, group.testUrl);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final groups = ref
        .watch(currentGroupsStateProvider)
        .value
        .where((g) => g.hidden != true)
        .toList();
    final hasProfile = ref.watch(profilesProvider.select((s) => s.isNotEmpty));
    final fallback = mainGroup(groups);
    final group = groups.firstWhere(
      (g) => g.name == _groupName,
      orElse: () => fallback ?? const Group(type: GroupType.Selector, name: ''),
    );

    if (groups.isEmpty) {
      return VpsPage(
        title: tr(context, '节点', 'Nodes'),
        subtitle: tr(context, '订阅中的全部节点', 'Every node in your subscription'),
        children: [
          VpsCard(
            padding: const EdgeInsets.all(36),
            child: Column(
              children: [
                VpsIconView(VpsIcon.servers, size: 40, color: p.accent),
                const SizedBox(height: 14),
                Text(
                  hasProfile
                      ? tr(context, '暂无可选节点', 'No nodes to choose')
                      : tr(context, '尚未导入订阅', 'No subscription yet'),
                  style: vpsText(context, size: 17, weight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  tr(
                    context,
                    '在「设置」中导入订阅后，节点将显示在这里',
                    'Import a subscription in Settings and its nodes appear here',
                  ),
                  textAlign: TextAlign.center,
                  style: vpsText(context, size: 13.5, color: p.soft),
                ),
                if (!hasProfile) ...[
                  const SizedBox(height: 18),
                  VpsButton(
                    label: tr(context, '导入订阅', 'Import'),
                    icon: VpsIcon.plus,
                    filled: true,
                    onTap: () => vpsTab.value = vpsTabMe,
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    }

    final selected = ref.watch(selectedProxyNameProvider(group.name));
    final selectable = group.type == GroupType.Selector;
    _autoTest(group);
    final byLatency = _byLatency.value;
    final delays = {
      for (final proxy in group.all)
        proxy.name: ref.watch(
          delayProvider(proxyName: proxy.name, testUrl: group.testUrl),
        ),
    };
    // The fastest real node (the smart/AI groups are not nodes).
    String? fastest;
    var best = 1 << 30;
    for (final proxy in group.all) {
      final d = delays[proxy.name];
      if (_isPinned(proxy.name) || d == null || d <= 0) continue;
      if (d < best) {
        best = d;
        fastest = proxy.name;
      }
    }
    final proxies = [...group.all];
    if (byLatency) {
      // Stable sort keeps the subscription order among equals; the smart and
      // AI lines stay on top because they are choices, not servers.
      final order = {for (final (i, x) in proxies.indexed) x.name: i};
      proxies.sort((a, b) {
        final pa = _isPinned(a.name) ? 0 : 1;
        final pb = _isPinned(b.name) ? 0 : 1;
        if (pa != pb) return pa - pb;
        final c = _rank(delays[a.name]).compareTo(_rank(delays[b.name]));
        return c != 0 ? c : order[a.name]!.compareTo(order[b.name]!);
      });
    }
    return VpsPage(
      title: tr(context, '节点', 'Nodes'),
      subtitle: selectable
          ? tr(context, '点击切换节点，延迟实时更新', 'Tap to switch; latency updates live')
          : tr(context, '该策略组自动选择节点', 'This group picks automatically'),
      action: VpsButton(
        label: _testing
            ? tr(context, '测速中…', 'Testing…')
            : tr(context, '测速', 'Test speed'),
        icon: VpsIcon.bolt,
        onTap: () => _test(group),
      ),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: groups.length > 1
                  ? Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final g in groups)
                          _GroupTab(
                            label: friendlyLineName(context, g.name),
                            selected: g.name == group.name,
                            onTap: () => setState(() => _groupName = g.name),
                          ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(width: 12),
            _GroupTab(
              label: byLatency
                  ? tr(context, '按延迟 ↑', 'By latency ↑')
                  : tr(context, '默认顺序', 'Default order'),
              selected: false,
              onTap: () => setState(() => _byLatency.value = !_byLatency.value),
            ),
          ],
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= 820 ? 3 : (c.maxWidth >= 520 ? 2 : 1);
            final w = (c.maxWidth - 12 * (cols - 1)) / cols;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final proxy in proxies)
                  SizedBox(
                    key: ValueKey(proxy.name),
                    width: w,
                    child: _ProxyCard(
                      proxy: proxy,
                      testUrl: group.testUrl,
                      fastest: proxy.name == fastest,
                      selected: proxy.name == selected,
                      onTap: selectable
                          ? () => ref
                                .read(proxiesActionProvider.notifier)
                                .changeProxy(
                                  groupName: group.name,
                                  proxyName: proxy.name,
                                )
                          : null,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _GroupTab extends StatelessWidget {
  const _GroupTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

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
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: ShapeDecoration(
          color: selected ? p.thumb : const Color(0x00000000),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: selected ? p.line : const Color(0x00000000),
            ),
          ),
          shadows: selected ? p.raise : null,
        ),
        child: Text(
          label,
          style: vpsText(
            context,
            size: 13.5,
            weight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? p.text : p.soft,
          ),
        ),
      ),
    );
  }
}

class _ProxyCard extends ConsumerWidget {
  const _ProxyCard({
    required this.proxy,
    required this.testUrl,
    required this.selected,
    this.fastest = false,
    this.onTap,
  });

  final Proxy proxy;
  final String? testUrl;
  final bool selected;
  final bool fastest;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = VpsPalette.of(context);
    final delay = ref.watch(
      delayProvider(proxyName: proxy.name, testUrl: testUrl),
    );
    final (delayText, delayColor) = switch (delay) {
      null => ('—', p.muted),
      0 => ('…', p.soft),
      < 0 => (tr(context, '超时', 'Timeout'), p.bad),
      < 200 => ('$delay ms', p.good),
      < 500 => ('$delay ms', p.warn),
      _ => ('$delay ms', p.bad),
    };
    return VpsCard(
      onTap: onTap,
      highlight: selected,
      selected: selected,
      radius: 14,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? p.accent : const Color(0x00000000),
              border: Border.all(
                color: selected ? p.accent : p.muted,
                width: 1.5,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        friendlyLineName(context, proxy.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: vpsText(
                          context,
                          size: 14,
                          weight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (fastest) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1.5,
                        ),
                        decoration: ShapeDecoration(
                          color: p.good.withValues(alpha: 0.12),
                          shape: RoundedSuperellipseBorder(
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                        child: Text(
                          tr(context, '最快', 'Fastest'),
                          style: vpsText(
                            context,
                            size: 10.5,
                            weight: FontWeight.w600,
                            color: p.good,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  proxy.name == vpsSmartGroupName
                      ? tr(
                          context,
                          '推荐 · 出口 IP 不变，协议受限自动切换',
                          'Recommended · same exit IP, auto protocol switch',
                        )
                      : proxy.name == vpsAIGroupName
                      ? tr(context, 'AI 服务固定出口', 'Steady exit for AI')
                      : protocolLabel(context, proxy.type) +
                            (proxy.name.toUpperCase().contains('REALITY') &&
                                    proxy.type.toLowerCase() == 'vless'
                                ? ' · REALITY'
                                : ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: vpsText(
                    context,
                    size: 12,
                    color: proxy.name == vpsSmartGroupName ? p.accent : p.soft,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            delayText,
            style: vpsText(
              context,
              size: 12.5,
              weight: FontWeight.w600,
              color: delayColor,
              tabular: true,
            ),
          ),
        ],
      ),
    );
  }
}
