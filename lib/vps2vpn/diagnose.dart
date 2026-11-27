// vps2vpn network diagnosis: this computer's network, DNS, the node, then a
// website, in order, stopping at the first that fails and saying in plain
// words what to do about it.

import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/home.dart' show mainGroup;
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/profile_health.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum VpsLeg { network, dns, node, site }

enum VpsLegState { waiting, running, ok, failed, skipped }

String _legTitle(BuildContext context, VpsLeg leg) => switch (leg) {
  VpsLeg.network => tr(context, '本机网络', 'This device\'s network'),
  VpsLeg.dns => tr(context, '域名解析（DNS）', 'Name lookup (DNS)'),
  VpsLeg.node => tr(context, '节点', 'Node'),
  VpsLeg.site => tr(context, '目标网站（Google）', 'A website (Google)'),
};

/// What to do when [leg] is the first to fail.
String vpsLegAdvice(
  BuildContext context,
  VpsLeg leg, {
  required bool on,
  bool subscriptionDown = false,
}) => switch (leg) {
  VpsLeg.network => tr(
    context,
    '这台电脑本身上不了网：检查 Wi-Fi 或网线，或者重启路由器。',
    'This computer is offline: check Wi-Fi or the cable, or restart the router.',
  ),
  VpsLeg.dns => tr(
    context,
    '网络已连通，但无法解析网站地址：请断开后重新连接；仍无法解决时请重启电脑。',
    'The network is up but site names do not resolve: disconnect and connect again; if that fails, restart the computer.',
  ),
  VpsLeg.node =>
    on && subscriptionDown
        ? tr(
            context,
            '本机网络正常，但节点和订阅链接都无法连接，问题在服务器一侧（服务器已停止或更换了地址），不是本机断网。请联系管理员获取新链接，然后在「设置」的订阅卡片上点击「替换链接」。',
            'Your network is fine, but neither the node nor the subscription link answers: the problem is on the server\'s side (it stopped or moved), not this device. Ask the owner for a new link, then ${vpsClick()} "Replace link" on the subscription card in Settings.',
          )
        : on
        ? tr(
            context,
            '本机网络正常，但节点无法连接：请在「节点」中更换节点；都无法连接时，请联系管理员检查服务器。',
            'Your network is fine but the node does not answer: pick another in Nodes; if none answers, ask the owner to check the server.',
          )
        : tr(
            context,
            '本机网络正常，还没有连接：请回到「概览」点击「连接」。',
            'Your network is fine; you are not connected yet: ${vpsClick()} "Connect" on Overview.',
          ),
  VpsLeg.site => tr(
    context,
    '节点可用，但这个网站无法访问：网站可能限制了该地区，请更换节点后重试。',
    'The node works but this site does not open: it may block the region; try another node.',
  ),
};

/// By address, so neither the Core nor DNS stands in the way.
const _bareHosts = [('223.5.5.5', 53), ('119.29.29.29', 53), ('1.1.1.1', 443)];

Future<bool> vpsReachesInternet({
  Future<Socket> Function(String host, int port, Duration timeout)? connect,
}) async {
  final dial =
      connect ??
      (host, port, timeout) => Socket.connect(host, port, timeout: timeout);
  final answers = await Future.wait([
    for (final (host, port) in _bareHosts)
      dial(host, port, const Duration(seconds: 4)).then((socket) {
        socket.destroy();
        return true;
      }, onError: (_) => false),
  ]);
  return answers.contains(true);
}

/// The last finished diagnosis, for a note to the admin.
final vpsLastDiagnosis =
    ValueNotifier<({DateTime at, Map<VpsLeg, VpsLegState> legs})?>(null);

class VpsDiagnoseCard extends ConsumerStatefulWidget {
  const VpsDiagnoseCard({super.key});

  @override
  ConsumerState<VpsDiagnoseCard> createState() => _VpsDiagnoseCardState();
}

class _VpsDiagnoseCardState extends ConsumerState<VpsDiagnoseCard> {
  final _states = {for (final leg in VpsLeg.values) leg: VpsLegState.waiting};
  VpsLeg? _failed;
  bool _running = false;
  int _run = 0;

  Future<bool> _check(VpsLeg leg) async {
    final core = ref.read(coreHandlerProvider);
    try {
      switch (leg) {
        case VpsLeg.network:
          return await vpsReachesInternet();
        case VpsLeg.dns:
          final found = await InternetAddress.lookup(
            'www.microsoft.com',
          ).timeout(const Duration(seconds: 6));
          return found.isNotEmpty;
        case VpsLeg.node:
          if (!ref.read(isStartProvider)) return false;
          final group = mainGroup(ref.read(currentGroupsStateProvider).value);
          final result = await lookupOutboundIp(
            core,
            group?.name ?? routedOutbound,
            timeout: const Duration(seconds: 10),
          );
          return parseOutboundIp(result) != null;
        case VpsLeg.site:
          final checks = await checkServices(
            core,
            targets: const [ServiceTarget.google],
          );
          return checks[ServiceTarget.google]?.status ==
              ServiceProbeStatus.available;
      }
    } catch (_) {
      return false;
    }
  }

  Future<void> _start() async {
    final run = ++_run;
    setState(() {
      _running = true;
      _failed = null;
      for (final leg in VpsLeg.values) {
        _states[leg] = VpsLegState.waiting;
      }
    });
    for (final leg in VpsLeg.values) {
      if (!mounted || run != _run) return;
      setState(() => _states[leg] = VpsLegState.running);
      final ok = await _check(leg);
      if (!mounted || run != _run) return;
      setState(() => _states[leg] = ok ? VpsLegState.ok : VpsLegState.failed);
      if (!ok) {
        setState(() {
          _failed = leg;
          for (final rest in VpsLeg.values.skip(leg.index + 1)) {
            _states[rest] = VpsLegState.skipped;
          }
        });
        break;
      }
    }
    if (mounted && run == _run) {
      setState(() => _running = false);
      vpsLastDiagnosis.value = (at: DateTime.now(), legs: Map.of(_states));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final on = ref.watch(isStartProvider);
    final profileId = ref.watch(currentProfileIdProvider);
    final subscriptionDown = ref.watch(
      vpsProfileHealthProvider.select((m) {
        final h = m[profileId];
        return h != null && !h.ok && h.unreachable;
      }),
    );
    final done =
        !_running && _states.values.every((s) => s != VpsLegState.waiting);
    final failed = _failed;
    return VpsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  failed != null
                      ? tr(
                          context,
                          '断在：${_legTitle(context, failed)}',
                          'Stops at: ${_legTitle(context, failed)}',
                        )
                      : done
                      ? tr(context, '每一段都通', 'Every step works')
                      : tr(
                          context,
                          '打不开网站时，从这里查断在哪一段',
                          'When sites do not open, find the step that fails',
                        ),
                  style: vpsText(
                    p,
                    size: 15,
                    weight: FontWeight.w600,
                    color: failed != null
                        ? p.bad
                        : done
                        ? p.good
                        : p.text,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              VpsButton(
                label: _running
                    ? tr(context, '诊断中…', 'Diagnosing…')
                    : tr(context, '开始诊断', 'Run diagnosis'),
                onTap: _running ? null : _start,
              ),
            ],
          ),
          if (failed != null) ...[
            const SizedBox(height: 8),
            Text(
              vpsLegAdvice(
                context,
                failed,
                on: on,
                subscriptionDown: subscriptionDown,
              ),
              style: vpsText(p, size: 13.5, color: p.soft, height: 1.5),
            ),
          ],
          const SizedBox(height: 8),
          for (final (i, leg) in VpsLeg.values.indexed) ...[
            if (i > 0) Container(height: 1, color: p.line),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _legTitle(context, leg),
                      style: vpsText(p, size: 14, weight: FontWeight.w500),
                    ),
                  ),
                  VpsBreathe(
                    active: _states[leg] == VpsLegState.running,
                    child: VpsChip(
                      label: switch (_states[leg]!) {
                        VpsLegState.waiting => tr(
                          context,
                          '未检查',
                          'Not checked',
                        ),
                        VpsLegState.running => tr(context, '检查中…', 'Checking…'),
                        VpsLegState.ok => tr(context, '正常', 'OK'),
                        VpsLegState.failed => tr(context, '不通', 'Fails'),
                        VpsLegState.skipped => tr(context, '已跳过', 'Skipped'),
                      },
                      color: switch (_states[leg]!) {
                        VpsLegState.ok => p.good,
                        VpsLegState.failed => p.bad,
                        _ => p.muted,
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
