// vps2vpn "Servers": pick the line you use, see how fast each one answers.

import 'package:fl_clash/common/dialog.dart' show dialogs;
import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/account.dart' show vpsDateTimeText;
import 'package:fl_clash/vps2vpn/home.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/node_status.dart';
import 'package:fl_clash/vps2vpn/profile_health.dart';
import 'package:fl_clash/vps2vpn/shell.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart'
    show BannerLevel, PopupAnchor, PopupMenu, PopupMenuItem, Tooltip;

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
    'ssr' => 'ShadowsocksR',
    'snell' => 'Snell',
    'mieru' => 'Mieru',
    'ssh' => 'SSH',
    'http' => 'HTTP',
    'socks5' => 'SOCKS5',
    'direct' => tr(context, '直连', 'Direct'),
    'reject' => tr(context, '拦截', 'Block'),
    'selector' => tr(context, '手动选择', 'Manual'),
    'urltest' => tr(context, '自动测速', 'URL test'),
    'fallback' => tr(context, '故障转移', 'Fallback'),
    'loadbalance' => tr(context, '负载均衡', 'Balanced'),
    _ => type,
  };
}

const _protocolWords = {
  'hysteria2': {'HYSTERIA2', 'HY2', 'HYSTERIA'},
  'hysteria': {'HYSTERIA', 'HY'},
  'vless': {'VLESS', 'REALITY'},
  'tuic': {'TUIC'},
  'trojan': {'TROJAN'},
  'vmess': {'VMESS'},
  'ss': {'SS', 'SHADOWSOCKS'},
  'shadowsocks': {'SS', 'SHADOWSOCKS'},
  'ssr': {'SSR', 'SHADOWSOCKSR'},
  'anytls': {'ANYTLS'},
  'wireguard': {'WIREGUARD', 'WG'},
  'snell': {'SNELL'},
  'mieru': {'MIERU'},
  'ssh': {'SSH'},
  'http': {'HTTP', 'HTTPS'},
  'socks5': {'SOCKS5', 'SOCKS'},
};

/// Whether a node's name already says its protocol ("SG · Hysteria2",
/// "JP Reality").
bool vpsNameSaysProtocol(String name, String type) {
  final words = _protocolWords[type.toLowerCase()];
  return words != null &&
      name.toUpperCase().split(RegExp('[^A-Z0-9]+')).any(words.contains);
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
(int?, String?, DateTime?)? _aiOkProfile;

(int?, String?, DateTime?) _profileKey(Profile? profile) =>
    (profile?.id, profile?.url, profile?.lastUpdateDate);

/// Sort key: answered lines by latency, then untested, then timeouts.
int _rank(int? d) => switch (d) {
  null || 0 => 1 << 20,
  < 0 => 1 << 21,
  final v => v,
};

bool _isPinned(String name) =>
    name == vpsSmartGroupName || name == vpsAIGroupName;

bool _isGroupType(String type) => const {
  'selector',
  'urltest',
  'fallback',
  'loadbalance',
  'relay',
}.contains(type.toLowerCase());

class _VpsServersPageState extends ConsumerState<VpsServersPage> {
  String? _groupName;
  bool _testing = false;
  bool _testingAi = false;
  var _aiRun = 0;

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

  void _cancelAi() {
    _aiRun++;
    if (_testingAi) setState(() => _testingAi = false);
  }

  Future<void> _testAi(Group group) async {
    if (_testingAi || !ref.read(isStartProvider)) return;
    setState(() => _testingAi = true);
    final run = ++_aiRun;
    final key = _profileKey(ref.read(currentProfileProvider));
    bool isCurrent() =>
        mounted &&
        run == _aiRun &&
        key == _profileKey(ref.read(currentProfileProvider)) &&
        ref.read(isStartProvider);
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
        if (!isCurrent()) return;
        await Future.wait([
          for (final name in names.skip(i).take(3))
            checkServices(
              core,
              proxyName: name,
              targets: const [ServiceTarget.claude, ServiceTarget.chatgpt],
            ).then<void>(
              (checks) {
                if (!isCurrent()) return;
                _aiOk.value = {
                  ..._aiOk.value,
                  name:
                      checks.values.length == 2 &&
                      checks.values.every(
                        (c) => c.status == ServiceProbeStatus.available,
                      ),
                };
              },
              onError: (Object _) {
                if (isCurrent()) {
                  _aiOk.value = {..._aiOk.value, name: false};
                }
              },
            ),
        ]);
      }
    } finally {
      if (mounted && run == _aiRun) setState(() => _testingAi = false);
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

  Future<void> _test(Group group, {bool tell = false}) async {
    if (_testing) return;
    setState(() => _testing = true);
    try {
      await ref
          .read(proxiesActionProvider.notifier)
          .delayTest(group.all, group.testUrl);
      if (tell && mounted) _tellTested(group);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _tellTested(Group group) {
    final nodes = [
      for (final proxy in group.all)
        if (!vpsBuiltinOutbound(proxy.name)) proxy,
    ];
    final ok = nodes.where((proxy) {
      final delay = ref.read(
        delayProvider(proxyName: proxy.name, testUrl: group.testUrl),
      );
      return delay != null && delay > 0;
    }).length;
    dialogs.showBanner(
      tr(
        context,
        '测速完成：${nodes.length} 个节点里 $ok 个能用',
        'Tested: $ok of ${nodes.length} nodes answer',
      ),
      level: ok > 0 ? BannerLevel.success : BannerLevel.warning,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentProfileProvider.select(_profileKey), (_, _) {
      _cancelAi();
    });
    ref.listen(isStartProvider, (_, running) {
      if (!running) _cancelAi();
    });
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
                    '导入订阅后，节点会显示在这里',
                    'Import a subscription and its nodes show up here',
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
    final status = vpsNodeStatusByName(ref.watch(vpsNodeStatusProvider));
    int standing(String name) => switch (status[name]?.state) {
      VpsNodeState.maintenance => 2,
      VpsNodeState.congested => 1,
      _ => 0,
    };
    if (status.isNotEmpty) {
      final order = {for (final (i, x) in proxies.indexed) x.name: i};
      proxies.sort((a, b) {
        final c = standing(a.name).compareTo(standing(b.name));
        return c != 0 ? c : order[a.name]!.compareTo(order[b.name]!);
      });
    }
    if (byLatency) {
      // Stable sort keeps the subscription order among equals; the smart and
      // AI lines stay on top because they are choices, not servers.
      final order = {for (final (i, x) in proxies.indexed) x.name: i};
      proxies.sort((a, b) {
        final pa = _isPinned(a.name) ? 0 : 1;
        final pb = _isPinned(b.name) ? 0 : 1;
        if (pa != pb) return pa - pb;
        final s = standing(a.name).compareTo(standing(b.name));
        if (s != 0) return s;
        final c = _rank(delays[a.name]).compareTo(_rank(delays[b.name]));
        return c != 0 ? c : order[a.name]!.compareTo(order[b.name]!);
      });
    }
    return VpsPage(
      title: tr(context, '节点', 'Nodes'),
      subtitle: selectable
          ? tr(
              context,
              '点击切换节点 · 延迟为打开测试网址的往返时间',
              '${vpsClick(start: true)} to switch · latency '
                  'to a test page',
            )
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
            onTap: _testing ? null : () => _test(group, tell: true),
          ),
        ],
      ),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: groups.length > 1
                  ? _GroupTabs(
                      names: [for (final g in groups) g.name],
                      selected: group.name,
                      onSelect: (name) => setState(() => _groupName = name),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(width: 12),
            _SortPill(
              byLatency: byLatency,
              onChanged: (v) => setState(() => _byLatency.value = v),
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

class _SortPill extends StatelessWidget {
  const _SortPill({required this.byLatency, required this.onChanged});

  final bool byLatency;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final latency = tr(context, '延迟从低到高', 'Fastest first');
    final listed = tr(context, '订阅原顺序', 'As subscribed');
    return PopupAnchor(
      targetBuilder: (open) => VpsPressable(
        onTap: open,
        semanticLabel: tr(context, '排序', 'Sort'),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 9, 6),
          decoration: ShapeDecoration(
            color: p.track,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(VpsRadius.pill),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                byLatency ? latency : listed,
                style: vpsText(
                  p,
                  size: 12.5,
                  weight: FontWeight.w500,
                  color: p.soft,
                ),
              ),
              const SizedBox(width: 3),
              RotatedBox(
                quarterTurns: 1,
                child: VpsIconView(VpsIcon.chevron, size: 13, color: p.muted),
              ),
            ],
          ),
        ),
      ),
      popupBuilder: (_) => PopupMenu(
        items: [
          PopupMenuItem(
            label: latency,
            checked: byLatency,
            onPressed: () => onChanged(true),
          ),
          PopupMenuItem(
            label: listed,
            checked: !byLatency,
            onPressed: () => onChanged(false),
          ),
        ],
      ),
    );
  }
}

/// The group tabs wrap onto two rows at most; past that they become one row
/// that scrolls sideways, fades at the edge that has more, and keeps the
/// selected tab in view.
class _GroupTabs extends StatefulWidget {
  const _GroupTabs({
    required this.names,
    required this.selected,
    required this.onSelect,
  });

  final List<String> names;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  State<_GroupTabs> createState() => _GroupTabsState();
}

class _GroupTabsState extends State<_GroupTabs> {
  static const _gap = 8.0;
  static const _maxRows = 2;
  final _scroll = ScrollController();
  final _selectedKey = GlobalKey();
  var _fadeStart = false;
  var _fadeEnd = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_edges);
    _reveal();
  }

  @override
  void didUpdateWidget(_GroupTabs old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) _reveal();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _selectedKey.currentContext;
      if (!mounted || target == null || !_scroll.hasClients) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.5,
        duration: VpsMotion.medium,
        curve: VpsMotion.settle,
      );
      _edges();
    });
  }

  void _edges() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final start = pos.pixels > 1;
    final end = pos.pixels < pos.maxScrollExtent - 1;
    if (start != _fadeStart || end != _fadeEnd) {
      setState(() {
        _fadeStart = start;
        _fadeEnd = end;
      });
    }
  }

  /// Rows a greedy wrap of [widths] takes in [max].
  static int _rows(List<double> widths, double max) {
    var rows = 1;
    var line = 0.0;
    for (final w in widths) {
      final next = line == 0 ? w : line + _gap + w;
      if (next > max && line > 0) {
        rows++;
        line = w;
      } else {
        line = next;
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final labels = [for (final n in widget.names) vpsGroupLabel(context, n)];
    final widths = [
      for (final label in labels)
        (TextPainter(
              text: TextSpan(
                text: label,
                style: vpsText(p, size: 13.5, weight: FontWeight.w600),
              ),
              textScaler: scaler,
              textDirection: TextDirection.ltr,
              maxLines: 1,
            )..layout()).width +
            30,
    ];
    Widget tab(int i) => _GroupTab(
      key: widget.names[i] == widget.selected ? _selectedKey : null,
      label: labels[i],
      tooltip: widget.names[i],
      selected: widget.names[i] == widget.selected,
      onTap: () => widget.onSelect(widget.names[i]),
    );
    return LayoutBuilder(
      builder: (context, c) {
        if (_rows(widths, c.maxWidth) <= _maxRows) {
          return Wrap(
            spacing: _gap,
            runSpacing: _gap,
            children: [for (var i = 0; i < labels.length; i++) tab(i)],
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => _edges());
        final row = Listener(
          // A mouse wheel moves the row sideways.
          onPointerSignal: (e) {
            if (e is! PointerScrollEvent || !_scroll.hasClients) return;
            final pos = _scroll.position;
            final delta = e.scrollDelta.dy != 0
                ? e.scrollDelta.dy
                : e.scrollDelta.dx;
            _scroll.jumpTo(
              (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent),
            );
          },
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < labels.length; i++) ...[
                  if (i > 0) const SizedBox(width: _gap),
                  tab(i),
                ],
              ],
            ),
          ),
        );
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => LinearGradient(
            colors: [
              Color(_fadeStart ? 0x00000000 : 0xFF000000),
              const Color(0xFF000000),
              const Color(0xFF000000),
              Color(_fadeEnd ? 0x00000000 : 0xFF000000),
            ],
            stops: [0, 24 / rect.width, 1 - 32 / rect.width, 1],
          ).createShader(rect),
          child: row,
        );
      },
    );
  }
}

class _GroupTab extends StatelessWidget {
  const _GroupTab({
    super.key,
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final String label;

  /// The group's own name, shown on hover when [label] renames it.
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final tab = VpsPressable(
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
          strutStyle: vpsStrut(13.5),
          style: vpsText(
            p,
            size: 13.5,
            weight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? p.text : p.soft,
          ),
        ),
      ),
    );
    return tooltip == label ? tab : Tooltip(message: tooltip, child: tab);
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
    final profileId = ref.watch(currentProfileIdProvider);
    final fresh = ref.watch(
      vpsProfileHealthProvider.select(
        (m) => m[profileId]?.isNew(proxy.name, DateTime.now()) ?? false,
      ),
    );
    final pinned = _isPinned(proxy.name);
    final status = pinned
        ? null
        : ref.watch(
            vpsNodeStatusProvider.select(
              (nodes) => vpsNodeStatusByName(nodes)[proxy.name],
            ),
          );
    final down = status?.state == VpsNodeState.maintenance;
    final busy = status?.state == VpsNodeState.congested;
    final label = vpsGroupLabel(context, proxy.name);
    final named = pinned || (_isGroupType(proxy.type) && label != proxy.name);
    final shown = named
        ? (name: label, rate: null)
        : vpsNodeTitle(context, proxy.name);
    final rate = shown.rate;
    final using = selected && !pinned;
    final protocol = vpsNameSaysProtocol(proxy.name, proxy.type)
        ? null
        : protocolLabel(context, proxy.type);
    final (delayText, delayColor) = switch (delay) {
      null => ('—', p.muted),
      0 => ('…', p.soft),
      < 0 => (tr(context, '超时', 'Timeout'), p.muted),
      < 200 => ('$delay ms', p.good),
      < 500 => ('$delay ms', p.warn),
      _ => ('$delay ms', p.soft),
    };
    final subtitle = _subtitle(context, p, status, protocol, rate, using);
    final tagged = down || busy || fresh || fastest || bestForAi || ai != null;
    return VpsCard(
      onTap: onTap,
      highlight: selected,
      selected: selected,
      radius: VpsRadius.medium,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Opacity(
        opacity: down ? 0.55 : 1,
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
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shown.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: vpsText(p, size: 14, weight: FontWeight.w600),
                  ),
                  if (tagged || subtitle.toPlainText().isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text.rich(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: vpsText(
                              p,
                              size: 12,
                              color: busy
                                  ? p.warn
                                  : proxy.name == vpsSmartGroupName || using
                                  ? p.accent
                                  : p.soft,
                            ),
                          ),
                        ),
                        if (down) ...[
                          const SizedBox(width: 8),
                          _Tag(tr(context, '维护中', 'Maintenance'), p.muted),
                        ] else if (busy) ...[
                          const SizedBox(width: 8),
                          _Tag(tr(context, '拥挤', 'Busy'), p.warn),
                        ],
                        if (fresh) ...[
                          const SizedBox(width: 8),
                          _Tag(tr(context, '新', 'New'), p.accent),
                        ],
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
                  ],
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
            _DelayCell(
              testing: delay == 0,
              text: delayText,
              color: delayColor,
              onRetest: () => ref
                  .read(proxiesActionProvider.notifier)
                  .delayTest([proxy], testUrl),
            ),
          ],
        ),
      ),
    );
  }
}

extension on _ProxyCard {
  /// Under the name: a notice, what the line does, or the protocol the name
  /// does not already say and the billing rate, after "In use" when chosen.
  TextSpan _subtitle(
    BuildContext context,
    VpsPalette p,
    VpsNodeStatus? status,
    String? protocol,
    double? rate,
    bool using,
  ) {
    if (status != null && status.note.isNotEmpty) {
      final until = status.until;
      return TextSpan(
        text:
            status.note +
            (until == null
                ? ''
                : tr(
                    context,
                    ' · 预计 ${vpsDateTimeText(context, until)} 恢复',
                    ' · back about ${vpsDateTimeText(context, until)}',
                  )),
      );
    }
    if (proxy.name == vpsSmartGroupName) {
      return TextSpan(
        text: using
            ? tr(context, '使用中 · 自动选最快', 'In use · auto')
            : tr(context, '推荐 · 自动选最快', 'Picks the fastest'),
      );
    }
    if (proxy.name == vpsAIGroupName) {
      return TextSpan(text: tr(context, 'AI 服务固定出口', 'Steady exit for AI'));
    }
    final parts = <InlineSpan>[
      if (using) TextSpan(text: tr(context, '使用中', 'In use')),
      if (protocol != null) TextSpan(text: protocol),
      if (rate != null)
        TextSpan(
          text: vpsRateText(rate),
          style: rate >= 2 ? TextStyle(color: p.warn) : null,
        ),
    ];
    return TextSpan(
      children: [
        for (final (i, part) in parts.indexed) ...[
          if (i > 0) const TextSpan(text: ' · '),
          part,
        ],
      ],
    );
  }
}

/// A node's delay. Pointing at it offers a test of this node alone; while a
/// test runs a placeholder breathes where the number will land.
class _DelayCell extends StatefulWidget {
  const _DelayCell({
    required this.testing,
    required this.text,
    required this.color,
    required this.onRetest,
  });

  final bool testing;
  final String text;
  final Color color;
  final VoidCallback onRetest;

  @override
  State<_DelayCell> createState() => _DelayCellState();
}

class _DelayCellState extends State<_DelayCell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final Widget shown = widget.testing
        ? const VpsSkeleton(key: ValueKey('testing'), width: 34, height: 10)
        : _hover
        ? VpsIconView(
            key: const ValueKey('retest'),
            VpsIcon.refresh,
            size: 15,
            color: p.soft,
          )
        : Text(
            widget.text,
            key: ValueKey(widget.text),
            textAlign: TextAlign.right,
            style: vpsText(
              p,
              size: 12.5,
              weight: FontWeight.w600,
              color: widget.color,
            ),
          );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: VpsPressable(
        onTap: widget.testing ? null : widget.onRetest,
        semanticLabel: tr(context, '重测这个节点', 'Test this node again'),
        child: SizedBox(
          width: 52,
          height: 28,
          child: Align(
            alignment: Alignment.centerRight,
            child: AnimatedSwitcher(duration: VpsMotion.medium, child: shown),
          ),
        ),
      ),
    );
  }
}

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

/// A node's leading tile: its country's flag, or a spark for the smart and
/// AI lines that fills with the accent when chosen.
class _NodeTile extends StatelessWidget {
  const _NodeTile({required this.label, required this.selected});

  final String? label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final ink = selected ? p.accentInk : p.soft;
    final filled = selected && label == null;
    return AnimatedContainer(
      duration: VpsMotion.medium,
      curve: VpsMotion.settle,
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        gradient: filled ? p.accentGradient : null,
        color: filled ? null : p.track,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(VpsRadius.medium),
          side: BorderSide(
            color: filled
                ? const Color(0x00000000)
                : selected
                ? p.accent
                : p.line,
            width: selected ? 1.5 : 1,
          ),
        ),
      ),
      child: label == null
          ? VpsIconView(VpsIcon.sparkle, size: 17, color: ink)
          : Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                VpsFlag(label!),
                Positioned(
                  right: -8,
                  bottom: -8,
                  child: AnimatedScale(
                    scale: selected ? 1 : 0,
                    duration: VpsMotion.medium,
                    curve: VpsMotion.settle,
                    child: Container(
                      width: 17,
                      height: 17,
                      alignment: Alignment.center,
                      decoration: ShapeDecoration(
                        gradient: p.accentGradient,
                        shape: RoundedSuperellipseBorder(
                          borderRadius: BorderRadius.circular(VpsRadius.pill),
                          side: BorderSide(color: p.card, width: 1.5),
                        ),
                      ),
                      child: VpsIconView(
                        VpsIcon.tick,
                        size: 11,
                        color: p.accentInk,
                      ),
                    ),
                  ),
                ),
              ],
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
