// vps2vpn network diagnosis: this computer's network, DNS, the node, then a
// website, in order, stopping at the first that fails and saying in plain
// words what to do about it.

import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/home.dart' show mainGroup;
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum VpsLeg { network, dns, node, site }

enum VpsLegState { waiting, running, ok, failed, skipped }

String _legTitle(BuildContext context, VpsLeg leg) => switch (leg) {
  VpsLeg.network => tr(context, '本机网络', 'This computer\'s network'),
  VpsLeg.dns => tr(context, '域名解析（DNS）', 'Name lookup (DNS)'),
  VpsLeg.node => tr(context, '节点', 'Node'),
  VpsLeg.site => tr(context, '目标网站（Google）', 'A website (Google)'),
};

/// What to do when [leg] is the first to fail.
String vpsLegAdvice(
  BuildContext context,
  VpsLeg leg, {
  required bool on,
}) => switch (leg) {
  VpsLeg.network => tr(
    context,
    '这台电脑本身上不了网：检查 Wi-Fi 或网线，或者重启路由器。',
    'This computer is offline: check Wi-Fi or the cable, or restart the router.',
  ),
  VpsLeg.dns => tr(
    context,
    '网能通，但查不到网站地址：断开再连接一次；还不行就重启电脑。',
    'The network is up but names do not resolve: disconnect and connect again, or restart the computer.',
  ),
  VpsLeg.node =>
    on
        ? tr(
            context,
            '本机网络正常，但节点连不上：到「节点」换一个；都不行就联系管理员看看服务器。',
            'Your network is fine but the node does not answer: pick another in Nodes, or ask the owner to check the server.',
          )
        : tr(
            context,
            '本机网络正常，还没有连接：回到「概览」点"连接"。',
            'Your network is fine; you are not connected yet: tap Connect on Overview.',
          ),
  VpsLeg.site => tr(
    context,
    '节点能用，但这个网站打不开：可能是网站限制了这个地区，换个节点试试。',
    'The node works but this site does not open: it may block the region; try another node.',
  ),
};

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
          final result = await lookupOutboundIp(
            core,
            directOutbound,
            timeout: const Duration(seconds: 8),
          );
          return parseOutboundIp(result) != null;
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
    if (mounted && run == _run) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final on = ref.watch(isStartProvider);
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
                    ? tr(context, '诊断中…', 'Running…')
                    : tr(context, '开始诊断', 'Diagnose'),
                onTap: _running ? null : _start,
              ),
            ],
          ),
          if (failed != null) ...[
            const SizedBox(height: 8),
            Text(
              vpsLegAdvice(context, failed, on: on),
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
                        VpsLegState.skipped => tr(context, '没查', 'Skipped'),
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
