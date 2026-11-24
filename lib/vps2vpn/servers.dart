// vps2vpn "Servers": pick the line you use, see how fast each one answers.

import 'package:fl_clash/common/service_probe.dart';
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

/// Groups already speed-tested for the current profile, so opening the page
/// again does not fire another round of probes.
final _autoTested = <String>{};
(int?, DateTime?)? _autoTestedProfile;

void _syncAutoTestProfile(WidgetRef ref) {
  final profile = ref.read(currentProfileProvider);
  final key = (profile?.id, profile?.lastUpdateDate);
  if (_autoTestedProfile != key) {
    _autoTestedProfile = key;
    _autoTested.clear();
  }
}

/// Speed-tests [group] once per profile session, after the current frame.
void vpsAutoTestOnce(WidgetRef ref, Group group) {
  if (group.name.isEmpty || group.all.isEmpty) return;
  _syncAutoTestProfile(ref);
  if (!_autoTested.add(group.name)) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!ref.context.mounted) return;
    ref
        .read(proxiesActionProvider.notifier)
        .delayTest(group.all, group.testUrl);
  });
}

/// Remembered for the whole app session, like the selected tab.
final _byLatency = ValueNotifier<bool>(true);

/// Per node: whether Claude and ChatGPT both open through it, from the last
/// "Test AI" this session.
final _aiOk = ValueNotifier<Map<String, bool>>(const {});
(int?, DateTime?)? _aiOkProfile;

(int?, DateTime?) _profileKey(Profile? profile) =>
    (profile?.id, profile?.lastUpdateDate);

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
  bool _testingAi = false;

  void _aiChanged() => setState(() {});

  @override
  void initState() {
    super.initState();
    _aiOk.addListener(_aiChanged);
  }

  @override
  void dispose() {
    _aiOk.removeListener(_aiChanged);
    super.dispose();
  }

  Future<void> _testAi(Group group) async {
    if (_testingAi) return;
    setState(() => _testingAi = true);
    final key = _profileKey(ref.read(currentProfileProvider));
    if (_aiOkProfile != key) {
      _aiOkProfile = key;
      _aiOk.value = const {};
    }
    final core = ref.read(coreHandlerProvider);
    final names = [
      for (final proxy in group.all)
        if (!_isPinned(proxy.name) && !vpsBuiltinOutbound(proxy.name))
          proxy.name,
    ];
    _aiOk.value = {
      for (final e in _aiOk.value.entries)
        if (!names.contains(e.key)) e.key: e.value,
    };
    try {
      for (var i = 0; i < names.length; i += 3) {
        await Future.wait([
          for (final name in names.skip(i).take(3))
            checkServices(
              core,
              proxyName: name,
              targets: const [ServiceTarget.claude, ServiceTarget.chatgpt],
            ).then(
              (checks) => _aiOk.value = {
                ..._aiOk.value,
                name:
                    checks.values.length == 2 &&
                    checks.values.every(
                      (c) => c.status == ServiceProbeStatus.available,
                    ),
              },
              onError: (_) => _aiOk.value = {..._aiOk.value, name: false},
            ),
        ]);
        if (!mounted) return;
      }
    } finally {
      if (mounted) setState(() => _testingAi = false);
    }
  }

  void _autoTest(Group group) {
    if (group.name.isEmpty || group.all.isEmpty || _testing) return;
    _syncAutoTestProfile(ref);
    if (!_autoTested.add(group.name)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _test(group);
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
                  style: vpsText(p, size: 17, weight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  tr(
                    context,
                    '在「设置」中导入订阅后，节点将显示在这里',
                    'Import a subscription in Settings and its nodes appear here',
                  ),
                  textAlign: TextAlign.center,
                  style: vpsText(p, size: 13.5, color: p.soft),
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
    final aiOk = _aiOkProfile == _profileKey(ref.watch(currentProfileProvider))
        ? _aiOk.value
        : const <String, bool>{};
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
    String? bestForAi;
    var bestAi = 1 << 30;
    for (final proxy in group.all) {
      final d = delays[proxy.name];
      if (aiOk[proxy.name] != true || d == null || d <= 0) continue;
      if (d < bestAi) {
        bestAi = d;
        bestForAi = proxy.name;
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
          : tr(
              context,
              '这条线路会自动挑选节点，不需要手动切换',
              'This line picks a node by itself; nothing to switch',
            ),
      action: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          VpsButton(
            label: _testingAi
                ? tr(context, '测 AI 中…', 'Testing AI…')
                : tr(context, '测 AI', 'Test AI'),
            icon: VpsIcon.sparkle,
            onTap: _testingAi || !ref.watch(isStartProvider)
                ? null
                : () => _testAi(group),
          ),
          VpsButton(
            label: _testing
                ? tr(context, '测速中…', 'Testing…')
                : tr(context, '测速', 'Test speed'),
            icon: VpsIcon.bolt,
            onTap: _testing ? null : () => _test(group),
          ),
        ],
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
              // Says how the list is sorted now; a tap switches it.
              label: byLatency
                  ? tr(context, '排序：延迟从低到高', 'Sort: fastest first')
                  : tr(context, '排序：订阅原顺序', 'Sort: as subscribed'),
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
                      ai: aiOk[proxy.name],
                      bestForAi: proxy.name == bestForAi,
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
        duration: VpsMotion.medium,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: ShapeDecoration(
          color: selected ? p.thumb : const Color(0x00000000),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(VpsRadius.small),
            side: BorderSide(
              color: selected ? p.line : const Color(0x00000000),
            ),
          ),
          shadows: selected ? p.raise : null,
        ),
        child: Text(
          label,
          style: vpsText(
            p,
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
    this.ai,
    this.bestForAi = false,
    this.onTap,
  });

  final Proxy proxy;
  final String? testUrl;
  final bool selected;
  final bool fastest;

  /// Whether Claude and ChatGPT open through this node; null until tested.
  final bool? ai;
  final bool bestForAi;
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
      < 0 => (tr(context, '超时', 'Timeout'), p.muted),
      < 200 => ('$delay ms', p.good),
      < 500 => ('$delay ms', p.warn),
      _ => ('$delay ms', p.soft),
    };
    return VpsCard(
      onTap: onTap,
      highlight: selected,
      selected: selected,
      radius: VpsRadius.medium,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          _NodeTile(
            label: switch (proxy.name) {
              vpsSmartGroupName || vpsAIGroupName => null,
              _ => vpsGuessCountry(proxy.name),
            },
            selected: selected,
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
                        style: vpsText(p, size: 14, weight: FontWeight.w600),
                      ),
                    ),
                    if (fastest) ...[
                      const SizedBox(width: 8),
                      _Tag(tr(context, '最快', 'Fastest'), p.good),
                    ],
                    if (bestForAi) ...[
                      const SizedBox(width: 8),
                      _Tag(tr(context, '适合 AI', 'Best for AI'), p.accent),
                    ] else if (ai != null) ...[
                      const SizedBox(width: 8),
                      _Tag(
                        ai!
                            ? tr(context, 'AI 可用', 'AI works')
                            : tr(context, 'AI 不可用', 'No AI'),
                        ai! ? p.accent : p.muted,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  proxy.name == vpsSmartGroupName
                      ? tr(
                          context,
                          '推荐 · 自动用最快的服务器',
                          'Recommended · uses the fastest server',
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
                    p,
                    size: 12,
                    color: proxy.name == vpsSmartGroupName ? p.accent : p.soft,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Signal bars, as on a phone: three for fast, one for slow, none
          // for no answer. Read before the number.
          _Bars(
            level: switch (delay) {
              null || 0 => -1,
              < 0 => 0,
              < 200 => 3,
              < 500 => 2,
              _ => 1,
            },
            color: delayColor,
            off: p.line,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 52,
            child: Text(
              delayText,
              textAlign: TextAlign.right,
              style: vpsText(
                p,
                size: 12.5,
                weight: FontWeight.w600,
                color: delayColor,
                tabular: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A node's leading tile: its country code, or a spark for the smart and
/// AI lines. Fills with the accent when chosen.
class _Tag extends StatelessWidget {
  const _Tag(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.12),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(VpsRadius.small),
        ),
      ),
      child: Text(
        label,
        style: vpsText(p, size: 10.5, weight: FontWeight.w600, color: color),
      ),
    );
  }
}

class _NodeTile extends StatelessWidget {
  const _NodeTile({required this.label, required this.selected});

  final String? label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final ink = selected ? p.accentInk : p.soft;
    return AnimatedContainer(
      duration: VpsMotion.medium,
      curve: VpsMotion.settle,
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        gradient: selected ? p.accentGradient : null,
        color: selected ? null : p.track,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(VpsRadius.medium),
          side: BorderSide(color: selected ? const Color(0x00000000) : p.line),
        ),
      ),
      child: label == null
          ? VpsIconView(VpsIcon.sparkle, size: 17, color: ink)
          : Text(
              label!,
              style: vpsText(
                p,
                size: 12.5,
                weight: FontWeight.w600,
                color: ink,
                spacing: 0.4,
              ),
            ),
    );
  }
}

/// Three rising bars, [level] of them lit (-1: not measured, all faint).
class _Bars extends StatelessWidget {
  const _Bars({required this.level, required this.color, required this.off});

  final int level;
  final Color color;
  final Color off;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 2.5),
          AnimatedContainer(
            duration: Duration(milliseconds: 300 + 80 * i),
            curve: Curves.easeOutBack,
            width: 4,
            height: 6.0 + 4 * i,
            decoration: ShapeDecoration(
              color: i < level ? color : off,
              shape: const RoundedSuperellipseBorder(
                borderRadius: BorderRadius.all(Radius.circular(VpsRadius.pill)),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
