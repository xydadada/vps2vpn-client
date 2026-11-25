// vps2vpn "Check": where the internet sees you, and which sites open.

import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/providers/outbound_ip.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/routed_probe.dart';
import 'package:fl_clash/providers/service_status.dart';
import 'package:fl_clash/vps2vpn/account.dart';
import 'package:fl_clash/vps2vpn/diagnose.dart';
import 'package:fl_clash/vps2vpn/exit_check.dart';
import 'package:fl_clash/vps2vpn/home.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:fl_clash/vps2vpn/shell.dart';
import 'package:fl_clash/vps2vpn/site_test.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _groups = [
  ('AI', [ServiceTarget.claude, ServiceTarget.chatgpt, ServiceTarget.gemini]),
  (
    '常用',
    [
      ServiceTarget.google,
      ServiceTarget.github,
      ServiceTarget.youtube,
      ServiceTarget.discord,
    ],
  ),
  (
    '影音',
    [
      ServiceTarget.netflix,
      ServiceTarget.disneyPlus,
      ServiceTarget.spotify,
      ServiceTarget.tiktok,
    ],
  ),
];

List<ServiceTarget> get _all => [for (final (_, ts) in _groups) ...ts];

String statusText(BuildContext context, ProbeEntry<ServiceCheck> entry) {
  final s = entry.value?.status;
  if (s == null) {
    return entry.isLoading
        ? tr(context, '检测中…', 'Checking…')
        : tr(context, '未检测', 'Not checked');
  }
  return switch (s) {
    ServiceProbeStatus.available => tr(context, '可用', 'Available'),
    ServiceProbeStatus.restricted => tr(context, '受限', 'Limited'),
    ServiceProbeStatus.originalsOnly => tr(context, '仅自制剧', 'Originals only'),
    ServiceProbeStatus.comingSoon => tr(context, '即将开放', 'Coming soon'),
    ServiceProbeStatus.unsupportedRegion => tr(
      context,
      '地区不支持',
      'Region unsupported',
    ),
    ServiceProbeStatus.disallowedIsp => tr(
      context,
      '机房 IP 受限',
      'Datacenter IP blocked',
    ),
    ServiceProbeStatus.blocked => tr(context, '已封锁', 'Blocked'),
    ServiceProbeStatus.unavailable => tr(context, '不可用', 'Unavailable'),
    ServiceProbeStatus.timeout => tr(context, '超时', 'Timed out'),
    ServiceProbeStatus.failed => tr(context, '检测失败', 'Check failed'),
  };
}

class VpsCheckPage extends ConsumerStatefulWidget {
  const VpsCheckPage({super.key});

  @override
  ConsumerState<VpsCheckPage> createState() => _VpsCheckPageState();
}

class _VpsCheckPageState extends ConsumerState<VpsCheckPage> {
  late final ServiceStatus _services;
  late final OutboundIpProbe _ip;
  bool _showIp = false;

  @override
  void initState() {
    super.initState();
    _services = ref.read(serviceStatusProvider.notifier);
    _ip = ref.read(outboundIpProbeProvider.notifier)..watch(routedOutbound);
    for (final t in _all) {
      _services.watch(t);
    }
  }

  @override
  void dispose() {
    for (final t in _all) {
      _services.unwatch(t);
    }
    _ip.unwatch(routedOutbound);
    super.dispose();
  }

  void _recheck() {
    _ip.refresh([routedOutbound]);
    _services.refresh(_all);
    ref.invalidate(vpsMemberProvider);
    ref.invalidate(vpsExitFactsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final isStart = ref.watch(isStartProvider);
    final ipEntry = ref.watch(
      outboundIpProbeProvider.select((s) => s.entryOf(routedOutbound)),
    );
    final info = ipEntry.value;
    final services = ref.watch(serviceStatusProvider);
    final working = _all
        .where(
          (t) =>
              services.entryOf(t).value?.status == ServiceProbeStatus.available,
        )
        .length;
    final checking = _all.any((t) => services.entryOf(t).isLoading);

    return VpsPage(
      title: tr(context, '检测', 'Check'),
      subtitle: tr(context, '出口信息与服务可达性', 'Exit and service reachability'),
      action: VpsButton(
        label: tr(context, '重新检测', 'Check again'),
        icon: VpsIcon.refresh,
        onTap: _recheck,
      ),
      children: [
        if (!isStart)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: VpsCard(
              onTap: () => vpsTab.value = vpsTabHome,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                children: [
                  VpsIconView(VpsIcon.info, size: 19, color: p.warn),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      tr(
                        context,
                        '未连接 · 以下为直连检测结果',
                        'Not connected · results below are direct',
                      ),
                      style: vpsText(p, type: VpsType.subhead),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (isStart) ...[VpsExitReport(exit: info), const SizedBox(height: 12)],
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= 640;
            final exit = VpsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(context, '出口', 'Exit'),
                    style: vpsText(
                      p,
                      type: VpsType.subhead,
                      color: p.soft,
                      weight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  AnimatedSwitcher(
                    duration: VpsMotion.medium,
                    child: info == null && ipEntry.isLoading
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 3),
                            child: VpsSkeleton(width: 120, height: 26),
                          )
                        : Text(
                            info == null
                                ? '—'
                                : countryName(context, info.countryCode),
                            key: ValueKey(info?.countryCode),
                            style: vpsText(
                              p,
                              type: VpsType.largeTitle,
                              weight: FontWeight.w600,
                              spacing: -0.5,
                            ),
                          ),
                  ),
                  const SizedBox(height: 10),
                  if (info != null)
                    VpsPressable(
                      onTap: () => setState(() => _showIp = !_showIp),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _showIp ? info.ip : _mask(info.ip),
                            style: vpsText(
                              p,
                              type: VpsType.body,
                              weight: FontWeight.w600,
                              color: p.soft,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _showIp
                                ? tr(context, '隐藏', 'Hide')
                                : tr(context, '显示', 'Show'),
                            style: vpsText(
                              p,
                              type: VpsType.subhead,
                              weight: FontWeight.w600,
                              color: p.accent,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            );
            final score = VpsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    checking
                        ? tr(context, '可访问（检测中…）', 'Reachable (checking…)')
                        : tr(context, '可访问', 'Reachable'),
                    style: vpsText(
                      p,
                      type: VpsType.subhead,
                      color: p.soft,
                      weight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$working',
                          style: vpsText(
                            p,
                            type: VpsType.largeTitle,
                            weight: FontWeight.w600,
                            color: p.text,
                            tabular: true,
                          ),
                        ),
                        TextSpan(
                          text: ' / ${_all.length}',
                          style: vpsText(
                            p,
                            type: VpsType.headline,
                            weight: FontWeight.w600,
                            color: p.soft,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  ClipRSuperellipse(
                    borderRadius: BorderRadius.circular(VpsRadius.pill),
                    child: SizedBox(
                      height: 8,
                      child: Stack(
                        children: [
                          Container(color: p.line),
                          FractionallySizedBox(
                            widthFactor: _all.isEmpty
                                ? 0
                                : working / _all.length,
                            child: Container(color: p.good),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
            if (!wide) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [exit, const SizedBox(height: 12), score],
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: exit),
                  const SizedBox(width: 12),
                  Expanded(child: score),
                ],
              ),
            );
          },
        ),
        for (final (name, targets) in _groups) ...[
          const SizedBox(height: 22),
          VpsSectionTitle(
            name == '常用'
                ? tr(context, '常用服务', 'Everyday')
                : name == '影音'
                ? tr(context, '流媒体', 'Streaming')
                : name,
          ),
          VpsCard(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            child: Column(
              children: [
                for (final (i, t) in targets.indexed) ...[
                  if (i > 0) Container(height: 1, color: p.line),
                  _ServiceLine(target: t, entry: services.entryOf(t)),
                ],
              ],
            ),
          ),
          if (name == 'AI') const VpsServerAiCard(),
        ],
        const SizedBox(height: 22),
        VpsSectionTitle(tr(context, '网站测试', 'Website test')),
        const VpsSiteTestCard(),
        const SizedBox(height: 22),
        VpsSectionTitle(tr(context, '网络诊断', 'Diagnosis')),
        const VpsDiagnoseCard(),
      ],
    );
  }
}

String _mask(String ip) {
  if (ip.contains(':')) {
    final parts = ip.split(':');
    return '${parts.first}:••••:••••';
  }
  final parts = ip.split('.');
  if (parts.length != 4) return '••••';
  return '${parts[0]}.••.••.${parts[3]}';
}

class _ServiceLine extends StatelessWidget {
  const _ServiceLine({required this.target, required this.entry});

  final ServiceTarget target;
  final ProbeEntry<ServiceCheck> entry;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final check = entry.value;
    final color = switch (check?.status) {
      null => p.muted,
      ServiceProbeStatus.available => p.good,
      ServiceProbeStatus.restricted ||
      ServiceProbeStatus.originalsOnly ||
      ServiceProbeStatus.comingSoon => p.warn,
      _ => p.bad,
    };
    final region = check?.region;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: ShapeDecoration(
              color: p.track,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(VpsRadius.small),
                side: BorderSide(color: p.line),
              ),
            ),
            child: serviceLogo(target, size: 16, color: p.text),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              target.label,
              style: vpsText(p, type: VpsType.body, weight: FontWeight.w500),
            ),
          ),
          if (region != null && region.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(
                region.toUpperCase(),
                style: vpsText(p, type: VpsType.footnote, color: p.soft),
              ),
            ),
          AnimatedSwitcher(
            duration: VpsMotion.medium,
            child: entry.value == null && entry.isLoading
                ? const VpsSkeleton(width: 64, height: 26)
                : VpsChip(
                    key: ValueKey(entry.value?.status),
                    label: statusText(context, entry),
                    color: color,
                  ),
          ),
        ],
      ),
    );
  }
}
