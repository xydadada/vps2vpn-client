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
import 'package:fl_clash/vps2vpn/takeover.dart' show vpsSystemTool;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Claude's own hosts, each asked through the rules for the address
/// Cloudflare sees.
const vpsClaudeHosts = ['claude.ai', 'api.anthropic.com'];

/// Where Claude does not serve, so an exit there cannot work.
const _unsupported = {'CN', 'HK', 'MO', 'RU', 'BY', 'IR', 'KP', 'SY', 'CU'};

final vpsClaudeTraceProvider = FutureProvider.autoDispose<Map<String, IpInfo?>>(
  (ref) async {
    if (!vpsWatchRoute(ref)) return const {};
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

/// The address both Claude hosts saw (an AI line's), else the general exit.
IpInfo? vpsClaudeExit(IpInfo? exit, Map<String, IpInfo?>? traces) {
  final seen = [for (final t in traces?.values ?? const <IpInfo?>[]) ?t];
  if (seen.isEmpty || seen.any((t) => !vpsSameIp(t.ip, seen.first.ip))) {
    return exit;
  }
  return seen.first;
}

const _proxyKeys = ['HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY'];

String? vpsProxyFromRegistry(String output) {
  for (final key in _proxyKeys) {
    final m = RegExp(
      '^\\s*$key\\s+REG_\\w+\\s+(.*)\$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(output);
    final value = m?[1]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

/// Read afresh on Windows: this process kept the variables it started with.
Future<String?> _terminalProxy() async {
  if (Platform.isWindows) {
    try {
      final r = await Process.run(vpsSystemTool('reg'), [
        'query',
        r'HKCU\Environment',
      ]);
      if (r.exitCode == 0) return vpsProxyFromRegistry('${r.stdout}');
    } catch (_) {}
  }
  final env = Platform.environment;
  for (final key in _proxyKeys) {
    final value = env[key] ?? env[key.toLowerCase()];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

bool vpsPointsHere(String proxy, int port) {
  final uri = Uri.tryParse(proxy.contains('://') ? proxy : 'http://$proxy');
  return uri != null &&
      uri.hasPort &&
      uri.port == port &&
      const ['127.0.0.1', 'localhost', '::1'].contains(uri.host.toLowerCase());
}

/// The rows only this page has: Claude itself, where it is reached from,
/// and the terminal proxy Claude Code uses.
List<VpsFinding> vpsClaudeFindings(
  BuildContext context, {
  required ProbeEntry<ServiceCheck> claude,
  required IpInfo? exit,
  required IpInfo? general,
  required Map<String, IpInfo?>? traces,
  required String? terminalProxy,
  required int port,
}) {
  final rows = <VpsFinding>[];
  final status = claude.value?.status;
  rows.add(
    VpsFinding(
      tr(context, 'Claude 能否打开', 'Can Claude open?'),
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
    final seen = [
      for (final t in traces.values)
        if (t != null) t.ip,
    ];
    final split = seen.any((ip) => !vpsSameIp(ip, seen.first));
    final missing = traces.values.any((t) => t == null);
    final apart =
        !split &&
        general != null &&
        seen.isNotEmpty &&
        !vpsSameIp(seen.first, general.ip);
    rows.add(
      VpsFinding(
        tr(context, 'Claude 各域名的出口', 'Exit for Claude\'s hosts'),
        split
            ? tr(context, '网页和 API 出口不同', 'Web and API use different exits')
            : missing
            ? tr(context, '有域名查不到', 'Some hosts did not answer')
            : apart
            ? tr(context, '同一专用出口', 'One dedicated exit')
            : tr(context, '同一出口', 'One exit'),
        split
            ? VpsFindingLevel.bad
            : missing
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
    final ours = proxy != null && vpsPointsHere(proxy, port);
    rows.add(
      VpsFinding(
        tr(context, '终端代理（Claude Code）', 'Terminal proxy (Claude Code)'),
        proxy == null
            ? tr(context, '没有设置', 'Not set')
            : ours
            ? tr(context, '指向 vps2vpn', 'Points to vps2vpn')
            : tr(context, '指向别处', 'Points elsewhere'),
        proxy == null
            ? VpsFindingLevel.none
            : ours
            ? VpsFindingLevel.good
            : VpsFindingLevel.warn,
        problem: proxy != null && !ours
            ? tr(
                context,
                '终端代理没有指向 vps2vpn',
                'the terminal proxy does not point to vps2vpn',
              )
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
  String? _terminal;

  @override
  void initState() {
    super.initState();
    _services = ref.read(serviceStatusProvider.notifier)
      ..watch(ServiceTarget.claude);
    _ip = ref.read(outboundIpProbeProvider.notifier)..watch(routedOutbound);
    _readTerminal();
  }

  @override
  void dispose() {
    _services.unwatch(ServiceTarget.claude);
    _ip.unwatch(routedOutbound);
    super.dispose();
  }

  Future<void> _readTerminal() async {
    final proxy = await _terminalProxy();
    if (mounted) setState(() => _terminal = proxy);
  }

  void _recheck() {
    _ip.refresh([routedOutbound]);
    _services.refresh([ServiceTarget.claude]);
    ref.invalidate(vpsExitFactsProvider);
    ref.invalidate(vpsClaudeTraceProvider);
    _readTerminal();
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final isStart = ref.watch(isStartProvider);
    return VpsPage(
      title: tr(context, 'Claude 环境检查', 'Claude environment'),
      subtitle: tr(
        context,
        '只检查环境是否一致；Anthropic 未公开其判断规则',
        'Checks only that things agree; Anthropic does not publish its rules',
      ),
      action: VpsButton(
        label: tr(context, '重新检测', 'Check again'),
        icon: VpsIcon.refresh,
        onTap: isStart ? _recheck : null,
      ),
      children: [
        if (!isStart)
          VpsCard(
            onTap: () => vpsTab.value = vpsTabHome,
            child: Text(
              tr(context, '请先连接，再进行检测', 'Connect first, then check'),
              style: vpsText(p, size: 14, color: p.warn),
            ),
          )
        else
          _report(context),
      ],
    );
  }

  Widget _report(BuildContext context) {
    final general = ref
        .watch(outboundIpProbeProvider.select((s) => s.entryOf(routedOutbound)))
        .value;
    final claude = ref.watch(
      serviceStatusProvider.select((s) => s.entryOf(ServiceTarget.claude)),
    );
    final traces = ref.watch(vpsClaudeTraceProvider);
    final facts = ref.watch(vpsExitFactsProvider);
    final exit = vpsClaudeExit(general, traces.value);
    final ip = exit?.ip;
    final quality = ip == null ? null : ref.watch(ipQualityProvider(ip)).value;
    final port = ref.watch(patchClashConfigProvider.select((s) => s.mixedPort));
    final rows = [
      ...vpsClaudeFindings(
        context,
        claude: claude,
        exit: exit,
        general: general,
        traces: traces.value,
        terminalProxy: _terminal,
        port: port,
      ),
      ...vpsExitFindings(
        context,
        exit: exit,
        quality: quality,
        facts: facts.value ?? (facts.isLoading ? null : const VpsExitFacts()),
        offset: DateTime.now().timeZoneOffset,
        localeName: Platform.localeName,
      ),
    ];
    final settled =
        exit != null &&
        !traces.isLoading &&
        !facts.isLoading &&
        claude.value != null;
    return VpsFindingCard(
      rows: rows,
      settled: settled,
      copyText: () => [
        vpsExitVerdict(context, rows),
        if (exit != null)
          '${tr(context, '出口', 'Exit')}: ${countryName(context, exit.countryCode)} ${vpsMaskLast(exit.ip)}',
        for (final r in rows) '${r.title}: ${r.value}',
      ].join('\n'),
    );
  }
}
