// vps2vpn home: one big connect button, where you exit, live speed,
// plan usage, how you go online, and whether the AI sites open.

import 'dart:async';
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
import 'package:fl_clash/vps2vpn/account.dart';
import 'package:fl_clash/vps2vpn/clipboard_import.dart';
import 'package:fl_clash/vps2vpn/flags.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/local_network.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:fl_clash/vps2vpn/screenshots.dart';
import 'package:fl_clash/vps2vpn/servers.dart';
import 'package:fl_clash/vps2vpn/shell.dart';
import 'package:fl_clash/vps2vpn/subscription_notice.dart';
import 'package:fl_clash/vps2vpn/takeover_notice.dart';
import 'package:fl_clash/vps2vpn/tun_ready.dart';
import 'package:fl_clash/vps2vpn/tray_menu.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

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

/// The country a node's name points at ("新加坡 Hysteria2", "US-2", "jp
/// reality"), as a two-letter code, or null.
final _flagPair = RegExp(r'[\u{1F1E6}-\u{1F1FF}]{2}', unicode: true);

// A billing rate at the end of a node name: "· 5.0x", "[2x]", "x0.5", "2倍".
final _rateTail = RegExp(
  r'(?:[\s·|_,，-]+|(?=[\[(（【]))[\[(（【]?\s*'
  r'(?:[x×]\s*(\d+(?:\.\d+)?)|(\d+(?:\.\d+)?)\s*(?:[x×]|倍率?)'
  r'|倍率\s*[:：]?\s*(\d+(?:\.\d+)?))'
  r'\s*[\])）】]?\s*$',
  caseSensitive: false,
);

({String name, double? rate}) vpsNodeName(String raw) {
  var name = raw;
  double? rate;
  final m = _rateTail.firstMatch(name);
  if (m != null && m.start > 0) {
    rate = double.tryParse(m[1] ?? m[2] ?? m[3]!);
    name = name.substring(0, m.start);
  }
  name = name.replaceAll(_flagPair, '').trim();
  return (name: name.isEmpty ? raw : name, rate: rate);
}

String? vpsGuessCountry(String name) {
  if (_flagPair.firstMatch(name)?.group(0) case final flag?) {
    final code = String.fromCharCodes([
      for (final r in flag.runes) r - 0x1F1E6 + 0x41,
    ]);
    if (_countryZh.containsKey(code)) return code;
  }
  for (final e in _countryZh.entries) {
    if (e.key != 'CN' && name.contains(e.value)) return e.key;
  }
  for (final x in RegExp(
    r'(?<![A-Za-z])[A-Za-z]{2}(?![A-Za-z])',
  ).allMatches(name)) {
    final word = x.group(0)!;
    final code = word.toUpperCase();
    if (code == 'CN' || !_countryZh.containsKey(code)) continue;
    if (_alsoEnglishWords.contains(code) && word != code) continue;
    return code;
  }
  return null;
}

const _alsoEnglishWords = {'IN', 'MY', 'ID'};

String countryName(BuildContext context, String code) {
  final c = code.toUpperCase();
  return vpsZh(context) ? (_countryZh[c] ?? c) : c;
}

/// What [group] uses now, past the smart line's hidden rate tiers.
String? vpsServerNow(List<Group> groups, Group? group) {
  var now = group?.now;
  for (var hops = 0; hops < 4; hops++) {
    if (now == null ||
        !(now.startsWith(vpsCheapGroupName) ||
            now.startsWith(vpsDearGroupName))) {
      break;
    }
    final name = now;
    now = groups.where((g) => g.name == name).firstOrNull?.now;
  }
  return now == null || now.isEmpty ? null : now;
}

String friendlyLineName(BuildContext context, String name) => switch (name) {
  vpsSmartGroupName => tr(context, '智能线路', 'Smart line'),
  vpsAIGroupName => tr(context, 'AI 专线', 'AI line'),
  _ => name,
};

const _builtinOutbounds = {
  'DIRECT',
  'REJECT',
  'REJECT-DROP',
  'PASS',
  'COMPATIBLE',
};

bool vpsBuiltinOutbound(String name) =>
    _builtinOutbounds.contains(name.trim().toUpperCase());

String _rateText(double rate) =>
    rate == rate.roundToDouble() ? '${rate.round()}' : '$rate';

/// The first selectable group whose first choice is a proxy, as the Core's
/// smart line picks it: what "the server you use" means here.
Group? mainGroup(List<Group> groups) {
  final selectors = [
    for (final g in groups)
      if (g.type == GroupType.Selector && g.hidden != true) g,
  ];
  for (final g in selectors) {
    final first = g.all.firstOrNull?.name;
    if (first == null || !vpsBuiltinOutbound(first)) return g;
  }
  return selectors.firstOrNull ?? groups.firstOrNull;
}

void useWholeSystem(WidgetRef ref, bool whole) =>
    vpsUseWholeSystem(ref.read, whole);

class VpsHomePage extends ConsumerWidget {
  const VpsHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = VpsPalette.of(context);
    final mode = ref.watch(patchClashConfigProvider.select((s) => s.mode));
    final tun = ref.watch(patchClashConfigProvider.select((s) => s.tun.enable));
    return VpsPage(
      title: tr(context, '概览', 'Overview'),
      children: [
        const VpsTakeoverNotice(),
        const VpsUpdateNotice(),
        const VpsSubscriptionNotice(),
        // Android would announce every read of the clipboard.
        if (!Platform.isAndroid) const VpsClipboardOffer(),
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
                        style: vpsText(p, size: 14.5, weight: FontWeight.w600),
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
                        style: vpsText(p, size: 14.5, weight: FontWeight.w600),
                      ),
                      const SizedBox(width: 8),
                      VpsInfoTip(
                        tr(
                          context,
                          '系统代理：设置系统代理，浏览器及遵循系统设置的应用生效，轻量、无需管理员权限。\n虚拟网卡（TUN）：在网络层接管全部流量，终端、游戏等不读取代理设置的程序同样生效，需要管理员权限。',
                          'System proxy: sets the system proxy; browsers and apps that honour it. No admin needed.\nTUN: a virtual adapter takes over all traffic at the network layer, terminals and games included. Needs admin.',
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
            if (Platform.isAndroid) return routing;
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
  final _importField = GlobalKey<VpsImportFieldState>();

  static const _connectWindow = Duration(seconds: 15);
  DateTime? _onSince;
  Timer? _settle;
  bool _tappedConnect = false;
  bool _tappedStop = false;
  String? _failure;

  void _toggle() {
    final starting = !ref.read(isStartProvider);
    setState(() {
      _tappedConnect = starting;
      _tappedStop = !starting;
      _failure = null;
    });
    ref.read(commonActionProvider.notifier).toggleRunning();
  }

  /// A login page cannot load through a line that is down, so off first.
  Future<void> _openLogin() async {
    if (ref.read(isStartProvider)) _toggle();
    for (var i = 0; i < 30 && ref.read(isStartProvider); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await launchUrl(vpsPortalPage, mode: LaunchMode.externalApplication);
  }

  /// "Connected" waits for the line to answer once; a start the app rolled
  /// back by itself says why, in place.
  void _onStartChanged(bool? was, bool now) {
    _settle?.cancel();
    if (now) {
      _onSince = DateTime.now();
      _settle = Timer(_connectWindow, () {
        if (mounted) setState(() {});
      });
      final group = mainGroup(ref.read(currentGroupsStateProvider).value);
      if (group != null) {
        unawaited(
          ref.read(proxiesActionProvider.notifier).delayTestGroups([group]),
        );
      }
      return;
    }
    _onSince = null;
    if (was == true && _tappedConnect && !_tappedStop) {
      final last = dialogs.lastErrorBanner;
      final recent =
          last != null &&
          DateTime.now().difference(last.at) < const Duration(seconds: 30);
      _failure = recent
          ? last.text
          : tr(context, '请再试一次。', 'Please try again.');
    }
    _tappedConnect = false;
    _tappedStop = false;
  }

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
      if (!Platform.isAndroid &&
          !ref.read(patchClashConfigProvider).tun.enable &&
          !ref.read(networkSettingProvider).systemProxy) {
        useWholeSystem(ref, false);
      }
      // Test hook: VPS2VPN_IMPORT_URL imports a subscription on first start.
      final testLink = vpsLoopbackLink(
        Platform.environment['VPS2VPN_IMPORT_URL'],
      );
      if (testLink != null && ref.read(profilesProvider).isEmpty) {
        ref.read(profilesActionProvider.notifier).addProfileFromLink(testLink);
      }
      vpsStartShots(ProviderScope.containerOf(context, listen: false));
    });
  }

  @override
  void dispose() {
    _settle?.cancel();
    _probe.unwatch(routedOutbound);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    ref.listen(
      isStartProvider,
      (was, now) => setState(() => _onStartChanged(was, now)),
    );
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
    final server = vpsServerNow(groups, pickedGroup);
    final line = picked == null
        ? null
        : server != null && on
        ? '${friendlyLineName(context, picked)} · $server'
        : friendlyLineName(context, picked);
    final dearRate =
        on &&
            picked == vpsSmartGroupName &&
            (pickedGroup?.now ?? '').startsWith(vpsDearGroupName)
        ? vpsNodeName(server ?? '').rate
        : null;

    final mode = ref.watch(patchClashConfigProvider.select((s) => s.mode));
    // What the panel says about the account outranks what the Core says:
    // connected to a server that refuses you is not connected.
    final block = vpsAccountBlock(ref.watch(vpsMemberProvider).value);
    final delay = group == null || !on
        ? null
        : ref.watch(
            delayProvider(proxyName: group.name, testUrl: group.testUrl),
          );
    final lineDown = on && delay != null && delay < 0;
    final localNet = lineDown ? ref.watch(vpsLocalNetProvider) : null;
    final netChecking = localNet != null && !localNet.hasValue;
    final netOff = localNet?.value == VpsLocalNet.offline;
    final portal = localNet?.value == VpsLocalNet.portal;
    final netFine = localNet?.value == VpsLocalNet.online;
    final onSince = _onSince;
    final tunReady = ref.watch(vpsTunReadyProvider).value;
    final lineUp = on && delay != null && delay > 0;
    final tunWaiting = lineUp && tunReady == null;
    final tunStuck = lineUp && tunReady == false;
    final connecting =
        on &&
        block == null &&
        (delay == null || delay == 0 || tunWaiting) &&
        onSince != null &&
        DateTime.now().difference(onSince) < _connectWindow;
    final failure = isStart || !hasProfile ? null : _failure;
    final (status, statusColor) = !hasProfile
        ? (tr(context, '未导入订阅', 'No subscription'), p.muted)
        : block != null
        ? (vpsAccountBlockReason(context, block), p.bad)
        : failure != null
        ? (tr(context, '没连上', 'Not connected'), p.bad)
        : connecting
        ? (tr(context, '连接中…', 'Connecting…'), p.muted)
        : suspended
        ? (tr(context, '已暂停', 'Paused'), p.warn)
        : netOff
        ? (tr(context, '本机没有联网', 'This computer is offline'), p.warn)
        : portal
        ? (tr(context, '网络需要先登录', 'This network wants a login'), p.warn)
        : netChecking
        ? (tr(context, '已连接 · 正在查原因', 'Connected · finding out why'), p.warn)
        : lineDown
        ? (tr(context, '已连接 · 线路无响应', 'Connected · line not answering'), p.warn)
        : tunStuck
        ? (tr(context, '已连接 · 网络还没通', 'Connected · not through yet'), p.warn)
        : on
        ? (tr(context, '已连接', 'Connected'), p.good)
        : (tr(context, '未连接', 'Not connected'), p.muted);
    // Connected, the headline is where you are (the capsule above it says
    // how well); otherwise what to do next.
    final title = !hasProfile
        ? tr(context, '导入订阅以开始', 'Import a subscription')
        : failure != null
        ? tr(context, '这次没连上', 'That did not connect')
        : connecting
        ? tr(context, '正在接入你的线路', 'Reaching your line')
        : on && info != null
        ? countryName(context, info.countryCode)
        : isStart
        ? (picked == null
              ? tr(context, '已连接', 'Connected')
              : friendlyLineName(context, picked))
        : tr(context, '准备就绪', 'Ready');
    // One colour for the whole state: capsule, button, ring and the light
    // behind the window. Null is "not connected": the brand's own colour.
    final tone = !hasProfile
        ? null
        : block != null || failure != null
        ? p.bad
        : connecting
        ? null
        : suspended || lineDown || tunStuck
        ? p.warn
        : on
        ? p.good
        : null;
    if (vpsAmbient.value != tone) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) vpsAmbient.value = tone;
      });
    }
    final latencyChip = !on || delay == null
        ? null
        : switch (delay) {
            0 => VpsChip(
              label: tr(context, '测速中…', 'Testing…'),
              color: p.muted,
            ),
            < 0 => VpsChip(label: tr(context, '延迟 —', '— ms'), color: p.muted),
            final d => VpsChip(
              label: tr(context, '延迟 $d ms', '$d ms'),
              color: d < 200 ? p.good : (d < 500 ? p.warn : p.soft),
            ),
          };
    final sub = !hasProfile
        ? tr(
            context,
            '把订阅链接粘贴到下面的框里，再点"导入"',
            'Paste your subscription link into the box below, then tap Import',
          )
        : block != null
        ? vpsAccountBlockHint(context, block)
        : failure ??
              (connecting
                  ? tr(
                      context,
                      '正在启动并测试线路，通常几秒就好',
                      'Starting up and testing the line; this takes a few seconds',
                    )
                  : suspended
                  ? tr(
                      context,
                      '连接已暂停，恢复后自动继续，也可点击"断开"停止',
                      'Connection paused; resumes automatically, or tap Disconnect',
                    )
                  : netOff
                  ? tr(
                      context,
                      '本机没有联网，请检查网线或 Wi‑Fi。联网后线路会自己恢复。',
                      'This computer is offline: check the cable or Wi-Fi. The '
                          'line comes back by itself once it is online.',
                    )
                  : portal
                  ? tr(
                      context,
                      '当前网络需要先登录（酒店、机场、公司常见）。点下方按钮会先断开，再打开登录页；登录后再连接。',
                      'This network wants a login first (hotels, airports, '
                          'offices). The button below disconnects and opens '
                          'the login page; connect again once logged in.',
                    )
                  : netChecking
                  ? tr(
                      context,
                      '线路没有响应，正在看是本机网络还是线路的问题…',
                      'The line is not answering; checking whether it is this '
                          "computer's network or the line…",
                    )
                  : lineDown && netFine
                  ? tr(
                      context,
                      '本机网络正常，但当前线路没有响应。到「节点」换一条，或到「检测」看看原因。',
                      'Your network is fine but the line is not answering. Pick '
                          'another in Nodes, or see Check.',
                    )
                  : lineDown
                  ? tr(
                      context,
                      '当前线路没有响应。到「节点」换一条，或到「检测」看看原因。',
                      'The line is not answering. Pick another in Nodes, or see Check.',
                    )
                  : tunStuck
                  ? tr(
                      context,
                      '线路能连上，但本机的网页还打不开（虚拟网卡的路由或 DNS 没生效）。到「检测」看原因，或到「节点」换一条；还不行就把下方的「接管方式」改成系统代理。',
                      'The line answers but pages do not load yet (the virtual '
                          "adapter's routes or DNS are not working). See Check, "
                          'or pick another node in Nodes; if that fails, set '
                          'Takeover below to System proxy.',
                    )
                  : dearRate != null
                  ? tr(
                      context,
                      '当前用的是 ×${_rateText(dearRate)} 计费线路（低倍率线路都连不上），流量按 ${_rateText(dearRate)} 倍扣',
                      'On a line billed at ${_rateText(dearRate)}x (none of the '
                          'cheaper lines answers); traffic counts '
                          '${_rateText(dearRate)} times',
                    )
                  : on && mode == Mode.global
                  ? tr(
                      context,
                      '全部流量正经由你的服务器加密传输',
                      'All traffic is encrypted through your server',
                    )
                  : on
                  ? tr(
                      context,
                      '境外流量正经由你的服务器加密传输，国内网站直连',
                      'Traffic abroad goes encrypted through your server; local sites go direct',
                    )
                  : tr(
                      context,
                      '轻点"连接"，即刻接入你的私有线路',
                      'Tap Connect to use your private line',
                    ));

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 640;
        final button = _PowerRing(
          on: on,
          busy: connecting,
          tone: tone ?? p.good,
          add: !hasProfile,
          size: wide ? 148 : 132,
          label: !hasProfile
              ? tr(context, '导入', 'Import')
              : connecting && !tunWaiting
              ? tr(context, '连接中…', 'Connecting…')
              : isStart
              ? tr(context, '断开', 'Disconnect')
              : failure != null
              ? tr(context, '重试', 'Retry')
              : tr(context, '连接', 'Connect'),
          onTap: !hasProfile
              ? () => _importField.currentState?.submitOrFill()
              : connecting && !tunWaiting
              ? null
              : _toggle,
        );
        final head = Column(
          crossAxisAlignment: wide
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            VpsChip(
              label: status,
              color: statusColor,
              tinted: true,
              beat: on && (delay ?? 0) > 0 ? delay : null,
            ),
            const SizedBox(height: 14),
            AnimatedSwitcher(
              duration: VpsMotion.medium,
              switchInCurve: VpsMotion.settle,
              switchOutCurve: VpsMotion.leave,
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: ScaleTransition(
                  scale: Tween(begin: 0.96, end: 1.0).animate(a),
                  alignment: wide ? Alignment.centerLeft : Alignment.center,
                  child: child,
                ),
              ),
              child: Row(
                key: ValueKey(title),
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (on && info != null) ...[
                    VpsFlag(info.countryCode, size: 30),
                    const SizedBox(width: 12),
                  ],
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: vpsText(
                        p,
                        size: wide ? 36 : 28,
                        weight: FontWeight.w600,
                        spacing: -0.8,
                        height: 1.15,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              sub,
              textAlign: wide ? TextAlign.start : TextAlign.center,
              style: vpsText(p, size: 13.5, color: p.soft, height: 1.5),
            ),
            if (portal) ...[
              const SizedBox(height: 12),
              VpsButton(
                label: tr(context, '断开并打开登录页', 'Disconnect and log in'),
                filled: true,
                onTap: _openLogin,
              ),
            ],
          ],
        );
        // The details as quiet capsules: latency coloured by how fast it is,
        // the rest neutral, so the eye lands on the one that matters.
        final meta = Padding(
          padding: const EdgeInsets.only(top: 22),
          child: Align(
            alignment: wide ? Alignment.centerLeft : Alignment.center,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: wide ? WrapAlignment.start : WrapAlignment.center,
              children: [
                ?latencyChip,
                if (on && info != null && line != null)
                  VpsChip(label: line, color: p.soft),
                if (on)
                  VpsChip(
                    label: tr(
                      context,
                      '时长 ${getTimeText(runTime)}',
                      'Up ${getTimeText(runTime)}',
                    ),
                    color: p.soft,
                  ),
              ],
            ),
          ),
        );
        return Container(
          clipBehavior: Clip.antiAlias,
          decoration: ShapeDecoration(
            color: p.card,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(VpsRadius.large),
              side: BorderSide(color: p.line),
            ),
            shadows: p.raise,
          ),
          child: Stack(
            children: [
              // The state's light pooled behind the button.
              Positioned(
                right: wide ? -110 : null,
                top: -130,
                left: wide ? null : 0,
                child: TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: tone ?? p.accent),
                  duration: const Duration(milliseconds: 700),
                  curve: VpsMotion.settle,
                  builder: (_, c, _) => Container(
                    width: 460,
                    height: 460,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          (c ?? p.accent).withValues(
                            alpha: p.dark ? (on ? 0.20 : 0.10) : 0.10,
                          ),
                          (c ?? p.accent).withValues(alpha: 0),
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
                    if (hasProfile)
                      meta
                    else
                      Padding(
                        padding: const EdgeInsets.only(top: 20),
                        child: VpsImportField(key: _importField),
                      ),
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

/// The connect button: a glowing ring that breathes while connected.
class _PowerRing extends StatefulWidget {
  const _PowerRing({
    required this.on,
    required this.tone,
    this.add = false,
    required this.size,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final bool on;

  /// The state's colour once connected (green, amber or red).
  final Color tone;
  final bool add;
  final double size;
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  State<_PowerRing> createState() => _PowerRingState();
}

class _PowerRingState extends State<_PowerRing> with TickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
    value: 1,
  );
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  late final Animation<double> _glow = _breath.drive(
    Tween<double>(
      begin: 0.72,
      end: 1,
    ).chain(CurveTween(curve: Curves.easeInOutSine)),
  );
  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
    _sync();
  }

  @override
  void didUpdateWidget(_PowerRing old) {
    super.didUpdateWidget(old);
    if (!old.on && widget.on && !_still) _ripple.forward(from: 0);
    if (old.busy != widget.busy || old.on != widget.on) _sync();
  }

  // Busy, the ring turns fast while the line is tried; connected, the glow
  // breathes once every four seconds.
  void _sync() {
    final period = Duration(milliseconds: widget.busy ? 1200 : 6000);
    final retimed = _spin.duration != period;
    _spin.duration = period;
    if (widget.on && !_still) {
      // repeat() carries on from the current angle; only a new speed needs it.
      if (retimed || !_spin.isAnimating) _spin.repeat();
      if (!_breath.isAnimating) _breath.repeat(reverse: true);
    } else {
      _spin.stop();
      _breath
        ..stop()
        ..value = 1;
      _ripple
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _breath.dispose();
    _ripple.dispose();
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
          clipBehavior: Clip.none,
          children: [
            // Outer glow in the state's colour (connected) or the brand's
            // (an invitation to connect).
            FadeTransition(
              opacity: _glow,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 600),
                curve: VpsMotion.settle,
                width: s,
                height: s,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: (widget.on ? widget.tone : p.seed).withValues(
                        alpha: widget.on ? 0.32 : 0.22,
                      ),
                      blurRadius: widget.on ? 56 : 36,
                    ),
                  ],
                ),
              ),
            ),
            // One wave out from the button the moment it connects.
            AnimatedBuilder(
              animation: _ripple,
              builder: (_, _) {
                final t = Curves.easeOutCubic.transform(_ripple.value);
                if (_ripple.value == 0 || _ripple.isCompleted) {
                  return const SizedBox.shrink();
                }
                return IgnorePointer(
                  child: Container(
                    width: s * (0.7 + 0.55 * t),
                    height: s * (0.7 + 0.55 * t),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: widget.tone.withValues(alpha: 0.4 * (1 - t)),
                        width: 2,
                      ),
                    ),
                  ),
                );
              },
            ),
            // Rotating ring, in the state's colour while connected.
            AnimatedBuilder(
              animation: _spin,
              builder: (_, _) => Transform.rotate(
                angle: _spin.value * 2 * math.pi,
                child: CustomPaint(
                  size: Size(s, s),
                  painter: _RingPainter(
                    on: widget.on,
                    track: p.line,
                    tone: widget.tone,
                  ),
                ),
              ),
            ),
            // Face: the filled brand button invites "connect"; once
            // connected it goes quiet and the colour moves to the ring.
            AnimatedContainer(
              duration: VpsMotion.slow,
              curve: VpsMotion.settle,
              width: s * 0.7,
              height: s * 0.7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: widget.on ? null : p.accentGradient,
                color: widget.on ? p.cardHi : null,
                border: Border.all(
                  color: widget.on
                      ? widget.tone.withValues(alpha: 0.45)
                      : const Color(0x00000000),
                  width: 1.5,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.add)
                    VpsIconView(
                      VpsIcon.plus,
                      size: s * 0.24,
                      color: p.accentInk,
                    )
                  else
                    CustomPaint(
                      size: Size.square(s * 0.2),
                      painter: _PowerGlyph(
                        widget.on ? widget.tone : p.accentInk,
                      ),
                    ),
                  SizedBox(height: s * 0.03),
                  Text(
                    widget.label,
                    style: vpsText(
                      p,
                      size: 13,
                      weight: FontWeight.w600,
                      color: widget.on ? p.text : p.accentInk,
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
  _RingPainter({required this.on, required this.track, required this.tone});

  final bool on;
  final Color track;
  final Color tone;

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
        ..shader = SweepGradient(
          endAngle: start + sweep,
          colors: [
            tone.withValues(alpha: 0),
            tone.withValues(alpha: 0.7),
            tone,
          ],
          stops: const [0, 0.55, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.on != on || old.track != track || old.tone != tone;
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
    final recent = traffics.list;
    final started = ref.watch(isStartProvider);
    final on = started && !ref.watch(suspendProvider);
    final total = ref.watch(totalTrafficProvider);
    final profile = ref.watch(currentProfileProvider);
    final sub = profile?.subscriptionInfo;
    // The panel's live numbers when it has answered, the ones the
    // subscription carried at its last update otherwise, so this tile and
    // the account card in Settings never disagree.
    final member = ref.watch(vpsMemberProvider).value?.member;
    TrafficShow? left;
    String? expire;
    if (member != null) {
      if (!member.unlimited) {
        final quota = (math.max(0, member.quotaGb) * 1024 * 1024 * 1024)
            .round();
        left = math.max(0, quota - member.used).traffic;
      }
      expire = vpsMemberExpiryText(context, member);
    } else {
      if (sub != null && sub.total > 0) {
        final remain = math.max(0, sub.total - sub.upload - sub.download);
        left = remain.traffic;
      }
      final expiry = sub?.expireDate;
      if (expiry != null) {
        expire = vpsExpiryText(context, expiry);
      }
    }
    final p = VpsPalette.of(context);
    final groups = ref.watch(currentGroupsStateProvider).value;
    final main = mainGroup(groups);
    if (main != null && on) vpsAutoTestOnce(ref, main);
    // Share of the plan still left, for the ring (null: unlimited/unknown).
    double? leftShare;
    if (member != null && !member.unlimited) {
      final quota = member.quotaGb * 1024 * 1024 * 1024;
      leftShare = quota > 0 ? (1 - member.used / quota).clamp(0.0, 1.0) : 0.0;
    } else if (member == null && sub != null && sub.total > 0) {
      leftShare = (1 - (sub.upload + sub.download) / sub.total).clamp(0.0, 1.0);
    }
    final tiles = <Widget>[
      // Down and up in one tile: one number big, the other its footnote.
      _Stat(
        icon: VpsIcon.arrowDown,
        label: tr(context, '实时速度', 'Speed'),
        value: on ? now.down.traffic.value : '—',
        unit: on ? '${now.down.traffic.unit}/s' : null,
        foot: on
            ? '↑ ${now.up.traffic.value} ${now.up.traffic.unit}/s'
            : tr(context, '连接后显示', 'Shown once connected'),
        spark: on ? [for (final t in recent) t.down + t.up] : null,
        sparkColor: p.good,
      ),
      _Stat(
        icon: VpsIcon.sparkle,
        label: tr(context, '本次流量', 'This session'),
        value: on ? (total.up + total.down).traffic.value : '—',
        unit: on ? (total.up + total.down).traffic.unit : null,
      ),
      if (left != null)
        _Stat(
          icon: VpsIcon.shield,
          label: tr(context, '剩余流量', 'Data left'),
          value: left.value,
          unit: left.unit,
          ring: leftShare,
          ringColor: leftShare == null
              ? p.accent
              : leftShare < 0.1
              ? p.bad
              : leftShare < 0.25
              ? p.warn
              : p.good,
        ),
      if (expire != null)
        _Stat(
          icon: VpsIcon.info,
          label: tr(context, '到期', 'Expires'),
          value: expire,
        ),
      // Latency is not repeated here: the hero's capsule already shows it.
    ];
    // Separate tiles with air between them (like iOS widgets), not one
    // table with rules: each number reads as its own thing.
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 680 ? tiles.length : 2;
        const gap = 12.0;
        final rows = <Widget>[];
        for (var i = 0; i < tiles.length; i += cols) {
          final slice = tiles.sublist(i, math.min(i + cols, tiles.length));
          if (i > 0) rows.add(const SizedBox(height: gap));
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (j, t) in slice.indexed) ...[
                    if (j > 0) const SizedBox(width: gap),
                    Expanded(
                      child: VpsCard(padding: EdgeInsets.zero, child: t),
                    ),
                  ],
                  // Keep the last row's tiles the same width as above.
                  for (var k = slice.length; k < cols; k++) ...[
                    const SizedBox(width: gap),
                    const Expanded(child: SizedBox.shrink()),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(children: rows);
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.icon,
    required this.label,
    required this.value,
    this.unit,
    this.foot,
    this.spark,
    this.sparkColor,
    this.ring,
    this.ringColor,
  });

  final VpsIcon icon;
  final String label;
  final String value;
  final String? unit;
  final String? foot;

  /// Recent samples drawn as a soft area chart under the number.
  final List<num>? spark;
  final Color? sparkColor;

  /// 0–1 drawn as a ring beside the number (data left of the plan).
  final double? ring;
  final Color? ringColor;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final spark = this.spark;
    final ring = this.ring;
    final text = Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Row(
        children: [
          Expanded(child: _text(p)),
          if (ring != null) ...[
            const SizedBox(width: 10),
            TweenAnimationBuilder<double>(
              tween: Tween(end: ring),
              duration: const Duration(milliseconds: 1100),
              curve: VpsMotion.settle,
              builder: (_, v, _) => CustomPaint(
                size: const Size.square(46),
                painter: _RingGauge(
                  value: v,
                  color: ringColor ?? p.accent,
                  track: p.line,
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return ClipRSuperellipse(
      borderRadius: BorderRadius.circular(VpsRadius.large),
      child: Stack(
        children: [
          if (spark != null && spark.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 44,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _SparkPainter(spark, sparkColor ?? p.accent),
                ),
              ),
            ),
          text,
        ],
      ),
    );
  }

  Widget _text(VpsPalette p) {
    return Column(
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
                  p,
                  size: 12,
                  color: p.soft,
                  weight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: VpsRollingText(
                value,
                style: vpsText(
                  p,
                  size: 22,
                  weight: FontWeight.w600,
                  spacing: -0.5,
                ),
              ),
            ),
            if (unit case final unit?) ...[
              const SizedBox(width: 4),
              Text(
                unit,
                style: vpsText(
                  p,
                  size: 13,
                  weight: FontWeight.w500,
                  color: p.soft,
                ),
              ),
            ],
          ],
        ),
        if (foot != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              foot!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: vpsText(p, size: 11.5, color: p.muted, tabular: true),
            ),
          ),
      ],
    );
  }
}

/// A round gauge: the track, then [value] of it in [color] from 12 o'clock.
class _RingGauge extends CustomPainter {
  _RingGauge({required this.value, required this.color, required this.track});

  final double value;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 5.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    if (value <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * value,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingGauge old) =>
      old.value != value || old.color != color || old.track != track;
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
                    borderRadius: BorderRadius.circular(VpsRadius.medium),
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
                      style: vpsText(p, size: 14.5, weight: FontWeight.w600),
                    ),
                    Text(
                      ref.watch(isStartProvider)
                          ? tr(context, '经由当前线路', 'Through the current line')
                          : tr(
                              context,
                              '未连接 · 当前为直连结果',
                              'Not connected · direct results',
                            ),
                      style: vpsText(p, size: 12.5, color: p.soft),
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
