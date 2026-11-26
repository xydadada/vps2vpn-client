// The overview line that says what Connect took over, or what is in its way.

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/window.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/takeover.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/checkbox.dart';
import 'package:prism_ui/prism_ui.dart' show AlertDialog, TextButton;

/// The first time Connect would close other apps: ask, and offer to remember.
Future<VpsTakeoverAnswer?> vpsShowTakeoverAsk(List<String> names) async {
  await window?.show();
  var remember = true;
  final close = await dialogs.showCommonDialog<bool>(
    dismissible: false,
    child: StatefulBuilder(
      builder: (context, setState) {
        final p = VpsPalette.of(context);
        final list = names.join(tr(context, '、', ', '));
        return AlertDialog(
          title: tr(context, '先关闭其他代理软件？', 'Close the other proxy apps?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(tr(context, '不关闭，直接连接', 'Connect without')),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(tr(context, '关闭并连接', 'Close and connect')),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(
                  context,
                  '$list 正在运行，它们会和 vps2vpn 抢系统代理和端口。关闭前请先保存它们里面没保存的设置。'
                      '选"不关闭"也能连接，只是可能互相冲突。',
                  '$list is running and will fight vps2vpn over the system '
                      'proxy and ports. Save anything unsaved in it first. '
                      'Connecting without closing works too, but they may '
                      'get in each other\'s way.',
                ),
                style: vpsText(p, size: 13.5, height: 1.5),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Checkbox(
                    value: remember,
                    onChanged: (v) => setState(() => remember = v ?? false),
                  ),
                  Expanded(
                    child: Text(
                      tr(
                        context,
                        '记住我的选择（可在"设置"里的"连接时自动接管"改）',
                        'Remember my choice (change it under Take over on '
                            'Connect in Settings)',
                      ),
                      style: vpsText(p, size: 12.5, color: p.soft),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    ),
  );
  return close == null ? null : (close: close, remember: remember);
}

class VpsTakeoverNotice extends ConsumerStatefulWidget {
  const VpsTakeoverNotice({super.key});

  @override
  ConsumerState<VpsTakeoverNotice> createState() => _VpsTakeoverNoticeState();
}

class _VpsTakeoverNoticeState extends ConsumerState<VpsTakeoverNotice> {
  bool _busy = false;
  VpsTakeoverReport? _dismissed;

  @override
  void initState() {
    super.initState();
    // Before the first Connect, show what would be in the way.
    vpsScanOnly(ourPort: ref.read(patchClashConfigProvider).mixedPort);
  }

  Future<void> _quit() async {
    if (_busy || safeModeBuild) return;
    setState(() => _busy = true);
    try {
      final names = vpsTakeoverReport.value.running;
      final still = await vpsQuitSorted(
        ourPort: ref.read(patchClashConfigProvider).mixedPort,
      );
      final last = vpsTakeoverReport.value;
      final closed = {
        ...last.closed.where((n) => !still.contains(n)),
        ...names.where((n) => !still.contains(n)),
      }.toList()..sort();
      vpsTakeoverReport.value = VpsTakeoverReport(
        closed: closed,
        stillRunning: still,
        portFrom: last.portFrom,
        portTo: last.portTo,
        clearedProxy: last.clearedProxy,
        dryRun: safeModeBuild,
        otherVpns: last.otherVpns,
        spared: last.spared,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final takeover = ref.watch(appSettingProvider.select((s) => s.takeover));
    return ValueListenableBuilder<VpsTakeoverReport>(
      valueListenable: vpsTakeoverReport,
      builder: (context, r, _) {
        if (r.isEmpty || identical(r, _dismissed)) {
          return const SizedBox.shrink();
        }
        final zh = <String>[];
        final en = <String>[];
        var warn = false;
        if (r.closed.isNotEmpty) {
          zh.add('已为你退出 ${r.closed.join('、')}，网络已由 vps2vpn 接管');
          en.add(
            '${r.closed.join(', ')} closed. vps2vpn now runs your network',
          );
        }
        if (r.stillRunning.isNotEmpty) {
          warn = true;
          zh.add(
            '${r.stillRunning.join('、')} 未能关闭（可能以管理员身份或服务模式运行），'
            '请在它的设置里关闭服务模式后手动退出',
          );
          en.add(
            '${r.stillRunning.join(', ')} did not close (it may run as '
            'administrator or as a service); turn its service mode off and '
            'quit it by hand',
          );
        }
        if (r.respawned.isNotEmpty) {
          warn = true;
          zh.add(
            '${r.respawned.join('、')} 关闭后又被自动重新启动（守护进程、服务模式或开机自启），'
            '会和 vps2vpn 争抢网络。请在它的设置里关闭这些功能，或将它卸载',
          );
          en.add(
            '${r.respawned.join(', ')} keeps starting again after it is closed '
            '(a watchdog, service mode or autostart) and fights vps2vpn over '
            'the network; turn those off in its settings, or uninstall it',
          );
        }
        if (r.contender != null) {
          warn = true;
          zh.add('${r.contender} 在和 vps2vpn 争抢系统代理，请退出它或关闭它的系统代理功能');
          en.add(
            '${r.contender} keeps taking the system proxy from vps2vpn; quit '
            'it or turn its system proxy off',
          );
        }
        if (r.running.isNotEmpty) {
          warn = true;
          zh.add(
            r.dryRun
                ? '检测到 ${r.running.join('、')} 正在运行（安全模式下不会关闭它）'
                : takeover
                ? '检测到 ${r.running.join('、')} 正在运行，连接时会自动关闭它'
                : '检测到 ${r.running.join('、')} 正在运行，它会和 vps2vpn 争抢网络设置',
          );
          en.add(
            '${r.running.join(', ')} is running'
            '${r.dryRun
                ? ' (left alone in safe mode)'
                : takeover
                ? '; Connect will close it'
                : ' and will fight over your network settings'}',
          );
        }
        if (r.spared.isNotEmpty) {
          warn = true;
          zh.add(
            '${r.spared.join('、')} 也在运行，可能和 vps2vpn 冲突。它没有占用系统代理或我们的端口，'
            '可能是别的程序或你自己在用，所以没有关闭',
          );
          en.add(
            '${r.spared.join(', ')} is running too and may clash with '
            'vps2vpn. It holds neither the system proxy nor our port and may '
            'belong to something else, so it was left running',
          );
        }
        if (r.otherVpns.isNotEmpty) {
          warn = true;
          zh.add(
            '另一个 VPN（${r.otherVpns.join('、')}）也开着，两个 VPN 同时开可能上不了网，'
            '请关掉其中一个',
          );
          en.add(
            'Another VPN (${r.otherVpns.join(', ')}) is on too; with two VPNs '
            'on, the internet may stop working. Turn one of them off',
          );
        }
        if (r.portTo != null) {
          zh.add('端口 ${r.portFrom} 被占用，已自动改用 ${r.portTo}');
          en.add('Port ${r.portFrom} was taken; now using ${r.portTo}');
        }
        if (r.clearedProxy) {
          zh.add('已清理其他软件留下的失效系统代理');
          en.add('Cleared a stale system proxy left by another app');
        }
        final color = warn ? p.warn : p.good;
        final canQuit = r.running.isNotEmpty && !r.dryRun && !takeover;
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: VpsCard(
            padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
            child: Row(
              crossAxisAlignment: zh.length == 1
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: zh.length == 1 ? 0 : 5),
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final (i, line) in zh.indexed)
                        Padding(
                          padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                          child: Text(
                            tr(context, line, en[i]),
                            style: vpsText(
                              p,
                              size: 13,
                              color: i == 0 ? p.text : p.soft,
                              height: 1.45,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (canQuit)
                  VpsButton(
                    label: tr(context, '一键退出', 'Quit them'),
                    onTap: _busy ? null : _quit,
                  )
                else
                  VpsPressable(
                    onTap: () => setState(() => _dismissed = r),
                    semanticLabel: tr(context, '关闭提示', 'Dismiss'),
                    child: SizedBox.square(
                      dimension: 32,
                      child: Center(
                        child: Text(
                          '×',
                          style: vpsText(p, size: 18, color: p.muted),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
