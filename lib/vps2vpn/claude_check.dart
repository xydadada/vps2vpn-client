// vps2vpn "Claude": whether this computer looks the same to Claude from
// every side. Anthropic does not publish how it judges an account, so this
// only checks that the environment is consistent.

import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/ip_quality.dart';
import 'package:fl_clash/providers/outbound_ip.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/routed_probe.dart';
import 'package:fl_clash/providers/service_status.dart';
import 'package:fl_clash/vps2vpn/check.dart' show statusText;
import 'package:fl_clash/vps2vpn/exit_check.dart';
import 'package:fl_clash/vps2vpn/home.dart' show countryName;
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/shell.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Claude's own hosts, each asked through the rules for the address
/// Cloudflare sees.
const vpsClaudeHosts = ['claude.ai', 'api.anthropic.com'];

/// Where Claude does not serve, so an exit there cannot work.
const _unsupported = {'CN', 'HK', 'MO', 'RU', 'BY', 'IR', 'KP', 'SY', 'CU'};

final vpsClaudeTraceProvider = FutureProvider.autoDispose<Map<String, IpInfo?>>(
  (ref) async {
    final link = ref.keepAlive();
    final timer = Timer(const Duration(minutes: 5), link.close);
    ref.onDispose(timer.cancel);
    final core = ref.read(coreHandlerProvider);
    final answers = await Future.wait([
      for (final host in vpsClaudeHosts)
        vpsAskCore(core, routedOutbound, ['https://$host/cdn-cgi/trace']),
    ]);
    return {
      for (final (i, host) in vpsClaudeHosts.indexed) host: _trace(answers[i]),
    };
  },
);

IpInfo? _trace(OutboundIpResult? result) {
  if (result == null || result.error != null) return null;
  try {
    return IpInfo.fromCloudflareTrace(result.body);
  } on FormatException {
    return null;
  }
}

/// The proxy a terminal started now would use, from the user's environment.
String? _terminalProxy() {
  final env = Platform.environment;
  for (final key in [
    'HTTPS_PROXY',
    'https_proxy',
    'HTTP_PROXY',
    'http_proxy',
    'ALL_PROXY',
    'all_proxy',
  ]) {
    final value = env[key];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

/// The rows only this page has: Claude itself, where it is reached from,
/// and the terminal proxy Claude Code uses.
List<VpsFinding> vpsClaudeFindings(
  BuildContext context, {
  required ProbeEntry<ServiceCheck> claude,
  required IpInfo? exit,
  required Map<String, IpInfo?>? traces,
  required String? terminalProxy,
  required int port,
}) {
  final rows = <VpsFinding>[];
  final status = claude.value?.status;
  rows.add(
    VpsFinding(
      tr(context, 'Claude 能否打开', 'Claude opens'),
      statusText(context, claude),
      switch (status) {
        null => VpsFindingLevel.none,
        ServiceProbeStatus.available => VpsFindingLevel.good,
        _ => VpsFindingLevel.bad,
      },
      problem: status == null || status == ServiceProbeStatus.available
          ? null
          : tr(context, 'Claude 打不开', 'Claude does not open'),
    ),
  );
  final country = exit?.countryCode.toUpperCase();
  if (country != null) {
    final blocked = _unsupported.contains(country);
    rows.add(
      VpsFinding(
        tr(context, '出口地区', 'Exit region'),
        countryName(context, country),
        blocked ? VpsFindingLevel.bad : VpsFindingLevel.good,
        problem: blocked
            ? tr(
                context,
                '出口地区 Claude 不支持',
                'Claude does not serve the exit region',
              )
            : null,
      ),
    );
  }
  if (traces != null) {
    final seen = {
      for (final t in traces.values)
        if (t != null) t.ip,
    };
    final split = seen.length > 1;
    final missing = traces.values.any((t) => t == null);
    final elsewhere =
        !split && exit != null && seen.isNotEmpty && !seen.contains(exit.ip);
    rows.add(
      VpsFinding(
        tr(context, 'Claude 各域名的出口', 'Exit for Claude\'s hosts'),
        split
            ? tr(context, '网页和 API 出口不同', 'web and API leave apart')
            : missing
            ? tr(context, '有域名查不到', 'some hosts did not answer')
            : elsewhere
            ? tr(context, '和其他网站出口不同', 'differs from other sites')
            : tr(context, '同一出口', 'one exit'),
        split
            ? VpsFindingLevel.bad
            : missing || elsewhere
            ? VpsFindingLevel.warn
            : VpsFindingLevel.good,
        problem: split
            ? tr(
                context,
                'Claude 网页和 API 走了不同出口',
                'Claude\'s web and API leave from different addresses',
              )
            : null,
      ),
    );
  }
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    final proxy = terminalProxy;
    final ours =
        proxy != null &&
        RegExp('(127\\.0\\.0\\.1|localhost):$port\\b').hasMatch(proxy);
    rows.add(
      VpsFinding(
        tr(context, '终端代理（Claude Code）', 'Terminal proxy (Claude Code)'),
        proxy == null
            ? tr(context, '没有设置', 'not set')
            : ours
            ? tr(context, '指向本软件', 'points here')
            : tr(context, '指向别处', 'points elsewhere'),
        proxy == null
            ? VpsFindingLevel.none
            : ours
            ? VpsFindingLevel.good
            : VpsFindingLevel.warn,
        problem: proxy != null && !ours
            ? tr(context, '终端代理没有指向本软件', 'the terminal proxy points elsewhere')
            : null,
      ),
    );
  }
  return rows;
}

class VpsClaudePage extends ConsumerStatefulWidget {
  const VpsClaudePage({super.key});

  @override
  ConsumerState<VpsClaudePage> createState() => _VpsClaudePageState();
}

class _VpsClaudePageState extends ConsumerState<VpsClaudePage> {
  late final ServiceStatus _services;
  late final OutboundIpProbe _ip;

  @override
  void initState() {
    super.initState();
    _services = ref.read(serviceStatusProvider.notifier)
      ..watch(ServiceTarget.claude);
    _ip = ref.read(outboundIpProbeProvider.notifier)..watch(routedOutbound);
  }

  @override
  void dispose() {
    _services.unwatch(ServiceTarget.claude);
    _ip.unwatch(routedOutbound);
    super.dispose();
  }

  void _recheck() {
    _ip.refresh([routedOutbound]);
    _services.refresh([ServiceTarget.claude]);
    ref.invalidate(vpsExitFactsProvider);
    ref.invalidate(vpsClaudeTraceProvider);
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final isStart = ref.watch(isStartProvider);
    final exit = ref
        .watch(outboundIpProbeProvider.select((s) => s.entryOf(routedOutbound)))
        .value;
    final claude = ref.watch(
      serviceStatusProvider.select((s) => s.entryOf(ServiceTarget.claude)),
    );
    final traces = ref.watch(vpsClaudeTraceProvider);
    final facts = ref.watch(vpsExitFactsProvider);
    final ip = exit?.ip;
    final quality = ip == null ? null : ref.watch(ipQualityProvider(ip)).value;
    final port = ref.watch(patchClashConfigProvider.select((s) => s.mixedPort));
    final rows = [
      ...vpsClaudeFindings(
        context,
        claude: claude,
        exit: exit,
        traces: traces.value,
        terminalProxy: _terminalProxy(),
        port: port,
      ),
      ...vpsExitFindings(
        context,
        exit: exit,
        quality: quality,
        facts: facts.value,
        offset: DateTime.now().timeZoneOffset,
        localeName: Platform.localeName,
      ),
    ];
    final settled =
        exit != null &&
        !traces.isLoading &&
        !facts.isLoading &&
        claude.value != null;
    return VpsPage(
      title: tr(context, 'Claude 环境检查', 'Claude environment'),
      subtitle: tr(
        context,
        '只看环境是否一致；Anthropic 没有公开它的判断规则',
        'Checks only that things agree; Anthropic does not publish its rules',
      ),
      action: VpsButton(
        label: tr(context, '重新检测', 'Check again'),
        icon: VpsIcon.refresh,
        onTap: _recheck,
      ),
      children: [
        if (!isStart)
          VpsCard(
            onTap: () => vpsTab.value = vpsTabHome,
            child: Text(
              tr(context, '先连接，再来这里检查', 'Connect first, then check here'),
              style: vpsText(p, size: 14, color: p.warn),
            ),
          )
        else
          VpsFindingCard(
            rows: rows,
            settled: settled,
            copyText: () => [
              vpsExitVerdict(context, rows),
              if (exit != null)
                '${tr(context, '出口', 'Exit')}: ${countryName(context, exit.countryCode)} ${vpsMaskLast(exit.ip)}',
              for (final r in rows) '${r.title}: ${r.value}',
            ].join('\n'),
          ),
      ],
    );
  }
}
