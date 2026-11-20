// vps2vpn home: one big connect button, where you exit, live speed,
// plan usage, how you go online, and whether the AI sites open.

import 'dart:io';
import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/outbound_ip.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/routed_probe.dart';
import 'package:fl_clash/providers/service_status.dart';
import 'package:fl_clash/vps2vpn/flags.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/servers.dart';
import 'package:fl_clash/vps2vpn/shell.dart';
import 'package:fl_clash/vps2vpn/takeover_notice.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

export 'package:fl_clash/vps2vpn/flags.dart'
    show vpsSmartGroupName, vpsAIGroupName;

const _countryZh = {
  'SG': '新加坡',
  'US': '美国',
  'JP': '日本',
  'HK': '香港',
  'TW': '台湾',
  'KR': '韩国',
  'DE': '德国',
  'GB': '英国',
  'FR': '法国',
  'NL': '荷兰',
  'AU': '澳大利亚',
  'CA': '加拿大',
  'IN': '印度',
  'MY': '马来西亚',
  'TH': '泰国',
  'VN': '越南',
  'PH': '菲律宾',
  'ID': '印度尼西亚',
  'RU': '俄罗斯',
  'CN': '中国',
  'MO': '澳门',
  'TR': '土耳其',
};

String countryName(BuildContext context, String code) {
  final c = code.toUpperCase();
  return vpsZh(context) ? (_countryZh[c] ?? c) : c;
}

String friendlyLineName(BuildContext context, String name) => switch (name) {
  vpsSmartGroupName => tr(context, '智能线路', 'Smart line'),
  vpsAIGroupName => tr(context, 'AI 专线', 'AI line'),
  _ => name,
};

/// The first selectable group: what "the server you use" means here.
Group? mainGroup(List<Group> groups) {
  for (final g in groups) {
    if (g.type == GroupType.Selector && g.hidden != true) return g;
  }
  return groups.isEmpty ? null : groups.first;
}

/// Whole system (virtual adapter) or the system proxy: exactly one of them.
void useWholeSystem(WidgetRef ref, bool whole) {
  ref
      .read(patchClashConfigProvider.notifier)
      .update((s) => s.copyWith.tun(enable: whole));
  ref
      .read(networkSettingProvider.notifier)
      .update((s) => s.copyWith(systemProxy: !whole));
}

class VpsHomePage extends ConsumerWidget {
  const VpsHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = VpsPalette.of(context);
    final mode = ref.watch(patchClashConfigProvider.select((s) => s.mode));
    final tun = ref.watch(patchClashConfigProvider.select((s) => s.tun.enable));
    return VpsPage(
      title: tr(context, '概览', 'Overview'),
      subtitle: tr(
        context,
        '私有线路，自主掌控',
        'Your private network, under your control',
      ),
      children: [
        const VpsTakeoverNotice(),
        const _Hero(),
        const SizedBox(height: 16),
        const _Stats(),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= 720;
            final routing = VpsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      VpsIconView(VpsIcon.globe, size: 17, color: p.soft),
                      const SizedBox(width: 10),
                      Text(
                        tr(context, '代理模式', 'Proxy mode'),
                        style: vpsText(context, size: 14.5, weight: FontWeight.w600),
                      ),
                      const SizedBox(width: 8),
                      VpsInfoTip(
                        tr(
                          context,
                          '规则模式：按分流规则决定去向，国内站点直连，境外流量走代理，兼顾速度与可达性。\n全局模式：所有流量一律经代理转发，适合规则未覆盖、需要完整出海的场景。',
                          'Rule: traffic follows the routing rules; domestic sites go direct, the rest via proxy.\nGlobal: everything goes through the proxy.',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  VpsSegmented<Mode>(
                    items: const [Mode.rule, Mode.global],
                    value: mode == Mode.direct ? Mode.rule : mode,
                    labelOf: (m) => m == Mode.rule
                        ? tr(context, '规则模式', 'Rule')
                        : tr(context, '全局模式', 'Global'),
                    onChanged: (m) =>
                        ref.read(setupActionProvider.notifier).changeMode(m),
                  ),
                ],
              ),
            );
            // One choice instead of two switches: having both on does nothing
            // more, and having both off silently takes over nothing.
            final takeover = VpsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      VpsIconView(VpsIcon.shield, size: 17, color: p.soft),
                      const SizedBox(width: 10),
                      Text(
                        tr(context, '接管方式', 'Takeover'),
                        style: vpsText(context, size: 14.5, weight: FontWeight.w600),
                      ),
                      const SizedBox(width: 8),
                      VpsInfoTip(
                        tr(
                          context,
                          '系统代理：设置 Windows 系统代理，浏览器及遵循系统设置的应用生效，轻量、无需管理员权限。\n虚拟网卡（TUN）：在网络层接管全部流量，终端、游戏等不读取代理设置的程序同样生效，需要管理员权限。',
                          'System proxy: sets the Windows proxy; browsers and apps that honour it. No admin needed.\nTUN: a virtual adapter takes over all traffic at the network layer, terminals and games included. Needs admin.',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  VpsSegmented<bool>(
                    items: const [false, true],
                    value: tun,
                    labelOf: (t) => t
                        ? tr(context, '虚拟网卡', 'TUN')
                        : tr(context, '系统代理', 'System proxy'),
                    onChanged: (t) => useWholeSystem(ref, t),
                  ),
                ],
              ),
            );
            if (!wide) {
              return Column(
                children: [routing, const SizedBox(height: 16), takeover],
              );
            }
            // No IntrinsicHeight: the segmented controls lay out with a
            // LayoutBuilder, which cannot report an intrinsic height.
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: routing),
                const SizedBox(width: 16),
                Expanded(child: takeover),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        const _AiStrip(),
      ],
    );
  }
}

class _Hero extends ConsumerStatefulWidget {
  const _Hero();

  @override
  ConsumerState<_Hero> createState() => _HeroState();
}

class _HeroState extends ConsumerState<_Hero> {
  late final OutboundIpProbe _probe;

  @override
  void initState() {
    super.initState();
    _probe = ref.read(outboundIpProbeProvider.notifier)..watch(routedOutbound);
    // Simple mode offers smart routing and proxy-all only; a "direct" left
    // over from advanced mode would look connected and route nothing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(patchClashConfigProvider).mode == Mode.direct) {
        ref.read(setupActionProvider.notifier).changeMode(Mode.rule);
      }
      // Test hook: VPS2VPN_IMPORT_URL imports a subscription on first start.
      final testLink = Platform.environment['VPS2VPN_IMPORT_URL'];
      if (testLink != null && ref.read(profilesProvider).isEmpty) {
        ref.read(profilesActionProvider.notifier).addProfileFromLink(testLink);
      }
    });
  }

  @override
  void dispose() {
    _probe.unwatch(routedOutbound);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final isStart = ref.watch(isStartProvider);
    final suspended = isStart && ref.watch(suspendProvider);
    final on = isStart && !suspended;
    final hasProfile = ref.watch(profilesProvider.select((s) => s.isNotEmpty));
    final runTime = ref.watch(runTimeProvider);
    final info = ref
        .watch(outboundIpProbeProvider.select((s) => s.entryOf(routedOutbound)))
        .value;
    final group = mainGroup(ref.watch(currentGroupsStateProvider).value);
    final picked = group == null
        ? null
        : ref.watch(selectedProxyNameProvider(group.name));
    final groups = ref.watch(currentGroupsStateProvider).value;
    final pickedGroup = groups.where((g) => g.name == picked).firstOrNull;
    final line = picked == null
        ? null
        : pickedGroup?.now?.isNotEmpty == true && on
        ? '${friendlyLineName(context, picked)} · ${pickedGroup!.now}'
        : friendlyLineName(context, picked);

    final mode = ref.watch(patchClashConfigProvider.select((s) => s.mode));
    final (status, statusColor) = !hasProfile
        ? (tr(context, '未导入订阅', 'No subscription'), p.muted)
        : suspended
        ? (tr(context, '已暂停', 'Paused'), p.warn)
        : on
        ? (tr(context, '已连接', 'Connected'), p.good)
        : (tr(context, '未连接', 'Disconnected'), p.muted);
    // Connected, the headline is where you are; otherwise what to do next.
    final title = !hasProfile
        ? tr(context, '导入订阅以开始', 'Import a subscription')
        : suspended
        ? tr(context, '已暂停', 'Paused')
        : on && info != null
        ? countryName(context, info.countryCode)
        : on
        ? tr(context, '已连接', 'Connected')
        : tr(context, '准备就绪', 'Ready');
    final sub = !hasProfile
        ? tr(
            context,
            '粘贴部署工具生成的订阅链接，即可使用你的私有线路',
            'Paste the link from the deploy tool to use your private line',
          )
        : suspended
        ? tr(
            context,
            '连接已暂停，恢复后自动继续，也可点击"断开"停止',
            'Connection paused; resumes automatically or tap Stop',
          )
        : on
        ? tr(
            context,
            '流量正经由你的服务器加密传输',
            'Traffic is encrypted through your server',
          )
        : tr(
            context,
            '轻点"连接"，即刻接入你的私有线路',
            'Tap Connect to use your private line',
          );

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 640;
        final button = _PowerRing(
          on: on,
          add: !hasProfile,
          size: wide ? 148 : 132,
          label: !hasProfile
              ? tr(context, '导入', 'Import')
              : (isStart
                    ? tr(context, '断开', 'Stop')
                    : tr(context, '连接', 'Connect')),
          onTap: hasProfile
              ? () => ref.read(commonActionProvider.notifier).toggleRunning()
              : () => vpsTab.value = vpsTabMe,
        );
        final head = Column(
          crossAxisAlignment: wide
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StatusDot(color: statusColor, pulse: on),
                const SizedBox(width: 8),
                Text(
                  status,
                  style: vpsText(
                    context,
                    size: 12.5,
                    weight: FontWeight.w500,
                    color: p.soft,
                    spacing: 0.3,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Text(
                title,
                key: ValueKey(title),
                style: vpsText(
                  context,
                  size: wide ? 34 : 28,
                  weight: FontWeight.w600,
                  spacing: -0.6,
                  height: 1.15,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              sub,
              textAlign: wide ? TextAlign.start : TextAlign.center,
              style: vpsText(context, size: 13.5, color: p.soft, height: 1.5),
            ),
          ],
        );
        final facts = [
          (
            tr(context, '出口', 'Exit'),
            on && info != null
                ? '${countryName(context, info.countryCode)} · ${info.countryCode.toUpperCase()}'
                : '—',
          ),
          (tr(context, '线路', 'Line'), line ?? '—'),
          (
            tr(context, '模式', 'Mode'),
            mode == Mode.global
                ? tr(context, '全局', 'Global')
                : tr(context, '规则', 'Rule'),
          ),
          (tr(context, '时长', 'Uptime'), on ? getTimeText(runTime) : '—'),
        ];
        final meta = Container(
          margin: const EdgeInsets.only(top: 26),
          padding: const EdgeInsets.only(top: 18),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: p.line)),
          ),
          child: Row(
            children: [
              for (final (i, (k, v)) in facts.indexed) ...[
                if (i > 0)
                  Container(
                    width: 1,
                    height: 30,
                    margin: EdgeInsets.symmetric(horizontal: wide ? 18 : 10),
                    color: p.line,
                  ),
                Expanded(
                  flex: i == 1 && wide ? 2 : 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        k,
                        style: vpsText(
                          context,
                          size: 11.5,
                          color: p.muted,
                          weight: FontWeight.w500,
                          spacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        v,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: vpsText(
                          context,
                          size: 13.5,
                          weight: FontWeight.w500,
                          tabular: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
        return Container(
          clipBehavior: Clip.antiAlias,
          decoration: ShapeDecoration(
            color: p.card,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: p.line),
            ),
            shadows: p.raise,
          ),
          child: Stack(
            children: [
              // A faint warm light behind the button; brighter when connected.
              Positioned(
                right: wide ? -120 : null,
                top: -140,
                left: wide ? null : 0,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 500),
                  opacity: on ? 1 : 0.45,
                  child: Container(
                    width: 460,
                    height: 460,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          vpsCoral.withValues(alpha: p.dark ? 0.16 : 0.10),
                          vpsCoral.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  wide ? 32 : 22,
                  wide ? 28 : 22,
                  wide ? 32 : 22,
                  wide ? 24 : 20,
                ),
                child: Column(
                  children: [
                    wide
                        ? Row(
                            children: [
                              Expanded(child: head),
                              const SizedBox(width: 24),
                              button,
                            ],
                          )
                        : Column(
                            children: [
                              button,
                              const SizedBox(height: 18),
                              head,
                            ],
                          ),
                    if (hasProfile) meta,
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatusDot extends StatefulWidget {
  const _StatusDot({required this.color, required this.pulse});

  final Color color;
  final bool pulse;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _c.repeat();
  }

  @override
  void didUpdateWidget(_StatusDot old) {
    super.didUpdateWidget(old);
    if (widget.pulse && !_c.isAnimating) _c.repeat();
    if (!widget.pulse && _c.isAnimating) _c.reset();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: 14,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Stack(
          alignment: Alignment.center,
          children: [
            if (widget.pulse)
              Container(
                width: 6 + 8 * _c.value,
                height: 6 + 8 * _c.value,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: 0.35 * (1 - _c.value)),
                ),
              ),
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The connect button: a glowing ring that breathes while connected.
class _PowerRing extends StatefulWidget {
  const _PowerRing({
    required this.on,
    this.add = false,
    required this.size,
    required this.label,
    required this.onTap,
  });

  final bool on;
  final bool add;
  final double size;
  final String label;
  final VoidCallback onTap;

  @override
  State<_PowerRing> createState() => _PowerRingState();
}

class _PowerRingState extends State<_PowerRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );

  @override
  void initState() {
    super.initState();
    if (widget.on) _spin.repeat();
  }

  @override
  void didUpdateWidget(_PowerRing old) {
    super.didUpdateWidget(old);
    if (widget.on && !_spin.isAnimating) _spin.repeat();
    if (!widget.on && _spin.isAnimating) _spin.stop();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final s = widget.size;
    return VpsPressable(
      onTap: widget.onTap,
      child: SizedBox(
        width: s,
        height: s,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Outer glow.
            AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              width: s,
              height: s,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: vpsCoral.withValues(alpha: widget.on ? 0.30 : 0),
                    blurRadius: widget.on ? 48 : 0,
                  ),
                ],
              ),
            ),
            // Rotating gradient ring.
            AnimatedBuilder(
              animation: _spin,
              builder: (_, _) => Transform.rotate(
                angle: _spin.value * 2 * math.pi,
                child: CustomPaint(
                  size: Size(s, s),
                  painter: _RingPainter(on: widget.on, track: p.line),
                ),
              ),
            ),
            // Face.
            AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              width: s * 0.7,
              height: s * 0.7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: widget.on ? p.accentGradient : null,
                color: widget.on ? null : p.track,
                border: widget.on ? null : Border.all(color: p.line),
                boxShadow: widget.on ? null : p.raise,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.add)
                    VpsIconView(VpsIcon.plus, size: s * 0.24, color: p.accent)
                  else
                    CustomPaint(
                      size: Size.square(s * 0.2),
                      painter: _PowerGlyph(
                        widget.on ? const Color(0xFFFFFFFF) : p.accent,
                      ),
                    ),
                  SizedBox(height: s * 0.03),
                  Text(
                    widget.label,
                    style: vpsText(
                      context,
                      size: 13,
                      weight: FontWeight.w600,
                      color: widget.on ? const Color(0xFFFFFFFF) : p.text,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.on, required this.track});

  final bool on;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 6;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = track,
    );
    if (!on) return;
    // The gradient spans only the arc, and the arc starts a little past 0
    // so its round cap never samples the violet end of the sweep.
    const start = 0.12;
    const sweep = math.pi * 1.4;
    canvas.drawArc(
      rect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..shader = const SweepGradient(
          endAngle: start + sweep,
          colors: [Color(0x00FF8A70), vpsCoralSoft, vpsCoralDeep, vpsViolet],
          stops: [0, 0.35, 0.7, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.on != on || old.track != track;
}

class _PowerGlyph extends CustomPainter {
  _PowerGlyph(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.42;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.1
      ..strokeCap = StrokeCap.round;
    const gap = math.pi / 3;
    canvas.drawArc(
      Rect.fromCircle(center: c.translate(0, r * 0.15), radius: r),
      -math.pi / 2 + gap / 2,
      2 * math.pi - gap,
      false,
      paint,
    );
    canvas.drawLine(
      c.translate(0, -r * 1.05),
      c.translate(0, -r * 0.05),
      paint,
    );
  }

  @override
  bool shouldRepaint(_PowerGlyph old) => old.color != color;
}

class _Stats extends ConsumerWidget {
  const _Stats();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final traffics = ref.watch(trafficsProvider);
    final now = traffics.list.safeLast(const Traffic());
    final all = traffics.list;
    final recent = all.length > 30 ? all.sublist(all.length - 30) : all;
    final total = ref.watch(totalTrafficProvider);
    final profile = ref.watch(currentProfileProvider);
    final sub = profile?.subscriptionInfo;
    String? left;
    String? expire;
    if (sub != null && sub.total > 0) {
      final remain = math.max(0, sub.total - sub.upload - sub.download);
      left = remain.traffic.show;
    }
    if (sub != null && sub.expire > 0) {
      final diff = DateTime.fromMillisecondsSinceEpoch(
        sub.expire * 1000,
      ).difference(DateTime.now());
      expire = diff.isNegative
          ? tr(context, '已到期', 'Expired')
          : tr(context, '还剩 ${diff.inDays} 天', '${diff.inDays} days left');
    }
    final p = VpsPalette.of(context);
    final groups = ref.watch(currentGroupsStateProvider).value;
    final main = mainGroup(groups);
    if (main != null && ref.watch(isStartProvider)) vpsAutoTestOnce(ref, main);
    final latency = main == null
        ? null
        : ref.watch(delayProvider(proxyName: main.name, testUrl: main.testUrl));
    final line = main == null
        ? null
        : friendlyLineName(
            context,
            ref.watch(selectedProxyNameProvider(main.name)) ?? '',
          );
    final tiles = [
      _Stat(
        icon: VpsIcon.arrowDown,
        label: tr(context, '下载', 'Down'),
        value: '${now.down.traffic.show}/s',
        spark: [for (final t in recent) t.down],
      ),
      _Stat(
        icon: VpsIcon.arrowUp,
        label: tr(context, '上传', 'Up'),
        value: '${now.up.traffic.show}/s',
        spark: [for (final t in recent) t.up],
      ),
      _Stat(
        icon: VpsIcon.sparkle,
        label: tr(context, '本次流量', 'This session'),
        value: (total.up + total.down).traffic.show,
      ),
      if (left != null || expire != null)
        _Stat(
          icon: VpsIcon.shield,
          label: left != null
              ? tr(context, '剩余流量', 'Data left')
              : tr(context, '到期', 'Expires'),
          value: left ?? expire!,
          foot: left != null ? expire : null,
        )
      else
        // Uptime is already in the hero; the line's latency says more here.
        _Stat(
          icon: VpsIcon.bolt,
          label: tr(context, '当前延迟', 'Latency'),
          value: switch (latency) {
            null => '—',
            0 => '…',
            < 0 => tr(context, '超时', 'Timeout'),
            final d => '$d ms',
          },
          foot: line,
        ),
    ];
    return VpsCard(
      padding: EdgeInsets.zero,
      child: LayoutBuilder(
        builder: (context, c) {
          final cols = c.maxWidth >= 680 ? 4 : 2;
          final rows = <Widget>[];
          for (var i = 0; i < tiles.length; i += cols) {
            final slice = tiles.sublist(i, math.min(i + cols, tiles.length));
            rows.add(
              Container(
                decoration: BoxDecoration(
                  border: i > 0 ? Border(top: BorderSide(color: p.line)) : null,
                ),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (j, t) in slice.indexed) ...[
                        if (j > 0) Container(width: 1, color: p.line),
                        Expanded(child: t),
                      ],
                    ],
                  ),
                ),
              ),
            );
          }
          return ClipRSuperellipse(
            borderRadius: BorderRadius.circular(16),
            child: Column(children: rows),
          );
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.icon,
    required this.label,
    required this.value,
    this.foot,
    this.spark,
  });

  final VpsIcon icon;
  final String label;
  final String value;
  final String? foot;

  /// Recent samples drawn as a soft area chart under the number.
  final List<num>? spark;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final spark = this.spark;
    return Stack(
      children: [
        if (spark != null && spark.length > 1)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 40,
            child: IgnorePointer(
              child: CustomPaint(painter: _SparkPainter(spark, p.accent)),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  VpsIconView(icon, size: 14, color: p.muted),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: vpsText(
                        context,
                        size: 12,
                        color: p.soft,
                        weight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: vpsText(
                  context,
                  size: 21,
                  weight: FontWeight.w600,
                  spacing: -0.4,
                  tabular: true,
                ),
              ),
              if (foot != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    foot!,
                    style: vpsText(context, size: 11.5, color: p.muted),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color);

  final List<num> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final top = values.fold<num>(0, math.max);
    if (top <= 0) return;
    final step = size.width / (values.length - 1);
    Offset at(int i) =>
        Offset(i * step, size.height - size.height * 0.9 * (values[i] / top));
    final line = Path()..moveTo(0, at(0).dy);
    for (var i = 1; i < values.length; i++) {
      final a = at(i - 1), b = at(i);
      final mid = (a.dx + b.dx) / 2;
      line.cubicTo(mid, a.dy, mid, b.dy, b.dx, b.dy);
    }
    final area = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.14), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values != values || old.color != color;
}

/// A site's own logo, tinted.
Widget serviceLogo(ServiceTarget t, {double size = 18, Color? color}) =>
    SvgPicture.asset(
      'assets/images/services/${t.icon}.svg',
      width: size,
      height: size,
      excludeFromSemantics: true,
      theme: SvgTheme(currentColor: color ?? const Color(0xFF888888)),
      colorFilter: color == null
          ? null
          : ColorFilter.mode(color, BlendMode.srcIn),
    );

const aiTargets = [
  ServiceTarget.claude,
  ServiceTarget.chatgpt,
  ServiceTarget.gemini,
];

/// "Can I use the AI sites right now?" in one line.
class _AiStrip extends ConsumerStatefulWidget {
  const _AiStrip();

  @override
  ConsumerState<_AiStrip> createState() => _AiStripState();
}

class _AiStripState extends ConsumerState<_AiStrip> {
  late final ServiceStatus _services;

  @override
  void initState() {
    super.initState();
    _services = ref.read(serviceStatusProvider.notifier);
    for (final t in aiTargets) {
      _services.watch(t);
    }
  }

  @override
  void dispose() {
    for (final t in aiTargets) {
      _services.unwatch(t);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final state = ref.watch(serviceStatusProvider);
    final chips = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final t in aiTargets) serviceChip(context, t, state.entryOf(t)),
      ],
    );
    return VpsCard(
      onTap: () => vpsTab.value = vpsTabCheck,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: LayoutBuilder(
        builder: (context, c) {
          final title = Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: ShapeDecoration(
                  color: p.track,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: p.line),
                  ),
                ),
                alignment: Alignment.center,
                child: VpsIconView(VpsIcon.sparkle, size: 18, color: p.accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(context, 'AI 服务可用性', 'AI availability'),
                      style: vpsText(context, size: 14.5, weight: FontWeight.w600),
                    ),
                    Text(
                      ref.watch(isStartProvider)
                          ? tr(context, '经由当前线路', 'Through the current line')
                          : tr(
                              context,
                              '未连接 · 当前为直连结果',
                              'Not connected · direct results',
                            ),
                      style: vpsText(context, size: 12.5, color: p.soft),
                    ),
                  ],
                ),
              ),
            ],
          );
          // Narrow: the chips get their own line instead of squeezing the title.
          if (c.maxWidth < 620) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, const SizedBox(height: 12), chips],
            );
          }
          return Row(
            children: [
              Expanded(child: title),
              const SizedBox(width: 12),
              chips,
            ],
          );
        },
      ),
    );
  }
}

/// Plain-word status chip for one site.
Widget serviceChip(
  BuildContext context,
  ServiceTarget t,
  ProbeEntry<ServiceCheck> entry,
) {
  final p = VpsPalette.of(context);
  final check = entry.value;
  final (mark, color) = switch (check?.status) {
    null => ('', p.muted),
    ServiceProbeStatus.available => ('', p.good),
    ServiceProbeStatus.restricted ||
    ServiceProbeStatus.originalsOnly ||
    ServiceProbeStatus.comingSoon => ('', p.warn),
    _ => ('', p.bad),
  };
  return VpsChip(label: t.label + mark, color: color);
}
