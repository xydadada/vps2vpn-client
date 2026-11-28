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
import 'package:fl_clash/vps2vpn/devices.dart';
import 'package:fl_clash/vps2vpn/exit_hold.dart';
import 'package:fl_clash/vps2vpn/feedback.dart';
import 'package:fl_clash/vps2vpn/flags.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/local_network.dart';
import 'package:fl_clash/vps2vpn/node_status.dart';
import 'package:fl_clash/vps2vpn/notice.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:fl_clash/vps2vpn/screenshots.dart';
import 'package:fl_clash/vps2vpn/servers.dart';
import 'package:fl_clash/vps2vpn/shell.dart';
import 'package:fl_clash/vps2vpn/stale_refresh.dart';
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

const _countryEn = {
  'SG': 'Singapore',
  'US': 'United States',
  'JP': 'Japan',
  'HK': 'Hong Kong',
  'TW': 'Taiwan',
  'KR': 'South Korea',
  'DE': 'Germany',
  'GB': 'United Kingdom',
  'FR': 'France',
  'NL': 'Netherlands',
  'AU': 'Australia',
  'CA': 'Canada',
  'IN': 'India',
  'MY': 'Malaysia',
  'TH': 'Thailand',
  'VN': 'Vietnam',
  'PH': 'Philippines',
  'ID': 'Indonesia',
  'RU': 'Russia',
  'CN': 'China',
  'MO': 'Macao',
  'TR': 'Türkiye',
};

const _placeEn = {
  '洛杉矶': 'Los Angeles',
  '圣何塞': 'San Jose',
  '硅谷': 'Silicon Valley',
  '西雅图': 'Seattle',
  '旧金山': 'San Francisco',
  '纽约': 'New York',
  '芝加哥': 'Chicago',
  '达拉斯': 'Dallas',
  '迈阿密': 'Miami',
  '阿什本': 'Ashburn',
  '东京': 'Tokyo',
  '大阪': 'Osaka',
  '首尔': 'Seoul',
  '春川': 'Chuncheon',
  '台北': 'Taipei',
  '伦敦': 'London',
  '法兰克福': 'Frankfurt',
  '巴黎': 'Paris',
  '阿姆斯特丹': 'Amsterdam',
  '悉尼': 'Sydney',
  '墨尔本': 'Melbourne',
  '多伦多': 'Toronto',
  '温哥华': 'Vancouver',
  '孟买': 'Mumbai',
  '吉隆坡': 'Kuala Lumpur',
  '曼谷': 'Bangkok',
  '胡志明市': 'Ho Chi Minh City',
  '河内': 'Hanoi',
  '马尼拉': 'Manila',
  '雅加达': 'Jakarta',
  '莫斯科': 'Moscow',
  '伊斯坦布尔': 'Istanbul',
  '迪拜': 'Dubai',
  '圣保罗': 'São Paulo',
};

const _countryShortEn = {'US': 'US', 'GB': 'UK', 'KR': 'Korea'};

/// English for the place a node's name starts with ("洛杉矶 Reality").
String vpsPlaceEn(String name) {
  final m = RegExp(r'^(\S+)(.*)$', dotAll: true).firstMatch(name);
  if (m == null) return name;
  final head = m[1]!;
  final code = _countryZh.entries
      .where((e) => e.value == head)
      .map((e) => e.key)
      .firstOrNull;
  final rest = m[2]!;
  // Before a protocol or a number, the short form keeps the card's one line.
  final en =
      _placeEn[head] ??
      (code == null
          ? null
          : rest.trim().isEmpty
          ? _countryEn[code]
          : _countryShortEn[code] ?? _countryEn[code]);
  return en == null ? name : '$en$rest';
}

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

// Our panel puts the protocol after the rate: "Tokyo ×2 Hysteria2".
final _protocolTail = RegExp(
  r'\s+(?:hysteria2?|hy2|reality|vless|tuic|trojan|vmess|ss|anytls|wireguard|wg)$',
  caseSensitive: false,
);

({String name, double? rate}) vpsNodeName(String raw) {
  var name = raw;
  double? rate;
  final tail = _protocolTail.firstMatch(name);
  final head = tail == null ? name : name.substring(0, tail.start);
  final m = _rateTail.firstMatch(head);
  if (m != null && m.start > 0) {
    final parsed = double.tryParse(m[1] ?? m[2] ?? m[3]!);
    if (parsed != null && parsed.isFinite) {
      rate = parsed;
      name = head.substring(0, m.start) + (tail?[0] ?? '');
    }
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

final _codeHead = RegExp(r'^([A-Za-z]{2})(?:[\s_|·-]+|(?=[^\x00-\x7F]))');

/// "us 洛杉矶 · 5.0x" reads "洛杉矶 · 5×": the flag already names the country.
String vpsNodeLabel(BuildContext context, String raw) {
  final (:name, :rate) = vpsNodeTitle(context, raw);
  return rate == null ? name : '$name · ${vpsRateText(rate)}';
}

/// A node's name without its country code, and its rate unless 1×. A code
/// followed only by a number ("US-2") keeps the country, spelled out.
({String name, double? rate}) vpsNodeTitle(BuildContext context, String raw) {
  final shown = vpsNodeShown(raw);
  final code = shown.code;
  final name = code == null
      ? shown.name
      : shown.name.isEmpty
      ? countryName(context, code)
      : RegExp(r'^\d+$').hasMatch(shown.name)
      ? '${countryName(context, code)} ${shown.name}'
      : vpsZh(context)
      ? shown.name
      : vpsPlaceEn(shown.name);
  return (name: name, rate: shown.rate == 1 ? null : shown.rate);
}

/// [vpsNodeName] less a leading country code; empty when the code was all.
({String name, String? code, double? rate}) vpsNodeShown(String raw) {
  final parsed = vpsNodeName(raw);
  final code = vpsGuessCountry(raw);
  var name = parsed.name;
  final head = _codeHead.firstMatch(name);
  if (code != null && head != null && head[1]!.toUpperCase() == code) {
    name = name.substring(head.end).trim();
  }
  if (code != null && name.toUpperCase() == code) name = '';
  if (code == null && name.isEmpty) name = parsed.name;
  return (name: name, code: code, rate: parsed.rate);
}

String countryName(BuildContext context, String code) {
  final c = code.toUpperCase();
  return (vpsZh(context) ? _countryZh : _countryEn)[c] ?? c;
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

const _panelGroupsEn = {
  '节点选择': 'Proxy',
  '自动选择': 'Auto',
  'AI服务': 'AI',
  '国内服务': 'China',
  '漏网之鱼': 'Final',
};
final _panelGroupsZh = {for (final e in _panelGroupsEn.entries) e.value: e.key};

final _emojiLead = RegExp(r'^([^\p{L}\p{N}\s]+\s*)(.+)$', unicode: true);

/// A group's name in the reader's language; a leading emoji, as in
/// "🚀 节点选择", stays and the rest is looked up.
String vpsGroupLabel(BuildContext context, String name) {
  final line = friendlyLineName(context, name);
  if (line != name) return line;
  final lead = _emojiLead.firstMatch(name);
  if (lead != null) return '${lead[1]}${vpsGroupLabel(context, lead[2]!)}';
  return (vpsZh(context) ? _panelGroupsZh : _panelGroupsEn)[name] ?? name;
}

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
    rate == rate.roundToDouble() ? rate.toStringAsFixed(0) : '$rate';

String vpsRateText(double rate) => '${_rateText(rate)}×';

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
        const VpsDeviceRemovedNotice(),
        const VpsFeedbackNotice(),
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
                        ? tr(context, '规则模式', 'Rule mode')
                        : tr(context, '全局模式', 'Global mode'),
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
                          'System proxy: browsers and apps that use the system proxy. No admin rights needed.\nVirtual adapter (TUN): takes over all traffic, terminals and games included. Needs admin rights.',
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
  late final _exit = VpsExitHold(
    onExpire: () {
      if (mounted) setState(() {});
    },
  );

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
      _failure = !recent
          ? tr(context, '请再试一次。', 'Please try again.')
          : vpsPageError.value == last.text
          ? tr(
              context,
              '原因见上方提示，处理好后再连接。',
              'The note above says why; connect again once it is sorted.',
            )
          : last.text;
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
    _exit.dispose();
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
    final info = _exit.steady(
      ref
          .watch(
            outboundIpProbeProvider.select((s) => s.entryOf(routedOutbound)),
          )
          .value,
      on: on,
    );
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
        ? '${friendlyLineName(context, picked)} · ${vpsNodeLabel(context, server)}'
        : vpsNodeLabel(context, friendlyLineName(context, picked));
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
    final pickedStatus =
        on && picked != vpsSmartGroupName && picked != vpsAIGroupName
        ? ref.watch(
            vpsNodeStatusProvider.select(
              (nodes) => vpsNodeStatusByName(nodes)[picked],
            ),
          )
        : null;
    final pickedDown = pickedStatus?.state == VpsNodeState.maintenance
        ? pickedStatus
        : null;
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
    final profileId = ref.watch(currentProfileProvider.select((p) => p?.id));
    final removed =
        !isStart &&
        profileId != null &&
        ref.watch(vpsRemovedProvider).contains(profileId);
    final (status, statusColor) = !hasProfile
        ? (tr(context, '未导入订阅', 'No subscription'), p.muted)
        : block != null
        ? (vpsAccountBlockReason(context, block), p.bad)
        : removed
        ? (tr(context, '此设备已被移除', 'Device removed'), p.bad)
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
        : !isStart && (block != null || removed)
        ? tr(context, '暂时不能连接', "Can't connect for now")
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
        : block != null || removed || failure != null
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
            < 0 => VpsChip(
              label: tr(context, '延迟 —', 'Latency —'),
              color: p.muted,
            ),
            final d => VpsChip(
              label: tr(context, '延迟 $d', 'Latency $d'),
              unit: 'ms',
              color: d < 200 ? p.good : (d < 500 ? p.warn : p.soft),
            ),
          };
    final sub = !hasProfile
        ? tr(
            context,
            '把订阅链接粘贴到下面的框里，再点击「导入」',
            'Paste your subscription link into the box below, then '
                '${vpsClick()} "Import"',
          )
        : block != null
        ? vpsAccountBlockHint(context, block)
        : removed
        ? tr(context, '处理方法见上方提示。', 'The note above says what to do.')
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
                      '连接已暂停，恢复后自动继续，也可点击「断开」停止',
                      'Connection paused; resumes automatically, or '
                          '${vpsClick()} "Disconnect"',
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
                  : pickedDown != null
                  ? vpsMaintenanceText(context, picked!, pickedDown)
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
                      '当前用的是 ${vpsRateText(dearRate)} 计费线路（低倍率线路都连不上），流量按 ${_rateText(dearRate)} 倍扣',
                      'On a line billed at ${vpsRateText(dearRate)} (none of the '
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
                      '点击「连接」接入你的私有网络',
                      '${vpsClick(start: true)} "Connect" to use your private network',
                    ));

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 640;
        // Breathing and spinning repaint the ring alone.
        final button = RepaintBoundary(
          child: _PowerRing(
            on: on,
            busy: connecting,
            tone: tone ?? p.good,
            add: !hasProfile,
            size: wide ? 148 : 132,
            off: removed,
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
          ),
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
                        spacing: -1.1,
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
              style: vpsText(p, size: 13.5, color: p.muted, height: 1.5),
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
    this.off = false,
  });

  final bool on;

  /// The state's colour once connected (green, amber or red).
  final Color tone;
  final bool add;
  final double size;
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  /// Nothing to connect to here: a grey face that does not press.
  final bool off;

  @override
  State<_PowerRing> createState() => _PowerRingState();
}

class _PowerRingState extends State<_PowerRing> with TickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  late final AnimationController _fill = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
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
  late final AnimationController _shift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..addListener(() => setState(() {}));
  late ColorTween _arc = ColorTween(begin: _arcTarget, end: _arcTarget);

  Color get _arcTarget =>
      widget.on ? widget.tone : widget.tone.withValues(alpha: 0);

  /// The arc's colour, transparent while not connected, eased between states.
  Color get _arcNow =>
      _arc.transform(VpsMotion.settle.transform(_shift.value))!;

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
    if (_arc.end != _arcTarget) {
      _arc = ColorTween(begin: _arcNow, end: _arcTarget);
      _still ? _shift.value = 1 : _shift.forward(from: 0);
    }
  }

  // Turning only while connecting; connected, a still closed ring and a glow.
  void _sync() {
    if (widget.on && widget.busy && !_still) {
      if (!_spin.isAnimating) _spin.repeat();
      _fill.value = 0;
    } else {
      _spin.stop();
      if (widget.on) {
        _still ? _fill.value = 1 : _fill.animateTo(1, curve: VpsMotion.settle);
      }
    }
    if (widget.on && !_still) {
      if (!_breath.isAnimating) _breath.repeat(reverse: true);
    } else {
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
    _fill.dispose();
    _breath.dispose();
    _ripple.dispose();
    _shift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final s = widget.size;
    final arc = _arcNow;
    final tone = arc.withValues(alpha: 1);
    final off = widget.off && !widget.on;
    return VpsPressable(
      onTap: off ? null : widget.onTap,
      child: SizedBox(
        width: s,
        height: s,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // Outer glow in the state's colour (connected) or the brand's
            // (an invitation to connect).
            if (!off)
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
                        color: (widget.on ? tone : p.seed).withValues(
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
                        color: tone.withValues(alpha: 0.4 * (1 - t)),
                        width: 2,
                      ),
                    ),
                  ),
                );
              },
            ),
            AnimatedBuilder(
              animation: Listenable.merge([_spin, _fill]),
              builder: (_, _) => Transform.rotate(
                angle: _spin.value * 2 * math.pi,
                child: CustomPaint(
                  size: Size(s, s),
                  painter: _RingPainter(
                    track: p.line,
                    tone: arc,
                    fill: _fill.value,
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
                gradient: widget.on || off ? null : p.accentGradient,
                color: widget.on
                    ? p.cardHi
                    : off
                    ? p.track
                    : null,
                border: Border.all(
                  color: widget.on
                      ? tone.withValues(alpha: 0.45)
                      : const Color(0x00000000),
                  width: 1.5,
                ),
              ),
              foregroundDecoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: widget.on && !p.dark
                    ? const RadialGradient(
                        center: Alignment(0, 0.12),
                        radius: 0.56,
                        colors: [Color(0x00000000), Color(0x0F000000)],
                        stops: [0.8, 1],
                      )
                    : LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(widget.on ? 0x14FFFFFF : 0x29FFFFFF),
                          const Color(0x00FFFFFF),
                        ],
                        stops: const [0, 0.55],
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
                        widget.on
                            ? tone
                            : off
                            ? p.muted
                            : p.accentInk,
                      ),
                    ),
                  SizedBox(height: s * 0.03),
                  Text(
                    widget.label,
                    style: vpsText(
                      p,
                      size: 13,
                      weight: FontWeight.w600,
                      color: widget.on
                          ? p.text
                          : off
                          ? p.muted
                          : p.accentInk,
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
  _RingPainter({required this.track, required this.tone, required this.fill});

  final Color track;
  final Color tone;
  final double fill;

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
    if (tone.a == 0) return;
    // The gradient spans only the arc, and the arc starts a little past 0
    // so its round cap never samples the violet end of the sweep.
    const start = 0.12;
    final sweep = math.pi * (1.4 + 0.6 * fill);
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
            tone.withValues(alpha: tone.a * fill),
            tone.withValues(alpha: tone.a * 0.7),
            tone,
          ],
          stops: [0, 0.55 - 0.05 * fill, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.track != track || old.tone != tone || old.fill != fill;
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
    int? plan;
    String? expire;
    DateTime? expireDate;
    if (member != null) {
      if (!member.unlimited) {
        plan = member.quotaBytes;
        if (plan != null) left = math.max(0, plan - member.used).traffic;
      }
      expire = vpsMemberExpiryText(context, member);
      expireDate = vpsMemberExpiryDate(member);
    } else {
      if (sub != null && sub.total > 0) {
        plan = sub.total;
        left = ((1 - sub.usage!) * sub.total).round().traffic;
      }
      expireDate = sub?.expireDate;
      if (expireDate != null) {
        expire = vpsExpiryText(context, expireDate);
      }
    }
    final unknownQuota = member != null && !member.unlimited && plan == null;
    // A ring against a terabyte plan stays full and says nothing.
    final hugePlan = plan != null && plan >= 1024 * 1024 * 1024 * 1024;
    final p = VpsPalette.of(context);
    final groups = ref.watch(currentGroupsStateProvider).value;
    final main = mainGroup(groups);
    if (main != null && on) vpsAutoTestOnce(ref, main);
    // Share of the plan still left, for the ring (null: unlimited/unknown).
    double? leftShare;
    if (plan != null && !hugePlan) {
      leftShare = member == null
          ? 1 - sub!.usage!
          : plan > 0
          ? (1 - member.used / plan).clamp(0.0, 1.0)
          : 0.0;
    }
    // Separate tiles with air between them (like iOS widgets), not one
    // table with rules: each number reads as its own thing.
    return LayoutBuilder(
      builder: (context, c) {
        final count =
            2 +
            (left != null || unknownQuota ? 1 : 0) +
            (expire == null ? 0 : 1);
        final cols = c.maxWidth >= 680 ? count : 2;
        const gap = 12.0;
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
            curveStrip: true,
          ),
          _Stat(
            icon: VpsIcon.sparkle,
            label: tr(context, '本次流量', 'This session'),
            value: on ? (total.up + total.down).traffic.value : '—',
            unit: on ? (total.up + total.down).traffic.unit : null,
          ),
          if (left != null || unknownQuota)
            _Stat(
              icon: VpsIcon.shield,
              label: tr(context, '剩余流量', 'Data left'),
              value: left?.value ?? '—',
              unit: left?.unit,
              foot: unknownQuota
                  ? tr(context, '配额未知', 'Quota unknown')
                  : hugePlan
                  ? tr(
                      context,
                      '共 ${plan!.traffic.value} ${plan.traffic.unit}',
                      'of ${plan.traffic.value} ${plan.traffic.unit}',
                    )
                  : null,
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
              foot: expireDate == null
                  ? null
                  : tr(
                      context,
                      '${vpsDateText(context, expireDate)}到期',
                      'Until ${vpsDateText(context, expireDate)}',
                    ),
            ),
          // Latency is not repeated here: the hero's capsule already shows it.
        ];
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
    this.curveStrip = false,
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

  /// A strip under the text for [spark], kept while there is nothing to
  /// draw so the tiles keep their height on connect.
  final bool curveStrip;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final spark = this.spark;
    final ring = this.ring;
    final body = Row(
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
              child: SizedBox.square(
                dimension: 46,
                child: Center(
                  child: Text(
                    '${(v * 100).round()}%',
                    textScaler: TextScaler.noScaling,
                    style: vpsText(
                      p,
                      size: 11,
                      weight: FontWeight.w600,
                      color: p.soft,
                      tabular: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
    if (!curveStrip) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: body,
      );
    }
    // Full width under the text, 6 dp clear of the text and the card's edge.
    return ClipRSuperellipse(
      borderRadius: BorderRadius.circular(VpsRadius.large),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            body,
            const SizedBox(height: 6),
            Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  height: 22,
                  child: spark == null || spark.length < 2
                      ? null
                      : IgnorePointer(
                          child: CustomPaint(
                            size: Size.infinite,
                            painter: _SparkPainter(
                              spark,
                              sparkColor ?? p.accent,
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _text(VpsPalette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
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
          mainAxisSize: MainAxisSize.min,
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

  // Nothing under 1 KB/s; a floor keeps a small blip off the top.
  static const _quiet = 1024;
  static const _floor = 16 * 1024;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 40 || size.height < 20) return;
    // About 3 dp a sample, so a narrow tile shows the last few seconds.
    final keep = math.max(8, size.width ~/ 3);
    final values = this.values.length > keep
        ? this.values.sublist(this.values.length - keep)
        : this.values;
    final peak = values.fold<num>(0, math.max);
    if (peak < _quiet) return;
    final top = math.max(peak, _floor);
    const stroke = 1.4;
    final rise = size.height - stroke;
    final step = size.width / (values.length - 1);
    Offset at(int i) =>
        Offset(i * step, stroke / 2 + rise * (1 - values[i] / top));
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
    final bounds = Offset.zero & size;
    canvas
      ..saveLayer(bounds, Paint())
      ..drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: 0.10), color.withValues(alpha: 0)],
          ).createShader(bounds),
      )
      ..drawPath(
        line,
        Paint()
          ..color = color.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke,
      )
      // A smoothstep fade-in from the left edge: flat at both ends, no seam.
      ..drawRect(
        bounds,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = const LinearGradient(
            colors: [
              Color(0x00000000),
              Color(0x1B000000),
              Color(0x5A000000),
              Color(0xA5000000),
              Color(0xE5000000),
              Color(0xFF000000),
            ],
            stops: [0, 0.07, 0.14, 0.21, 0.28, 0.35],
          ).createShader(bounds),
      )
      ..restore();
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
                          ? tr(context, '经由当前节点', 'Through the current node')
                          : tr(
                              context,
                              '未连接 · 以下为直连结果',
                              'Not connected · direct results below',
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
