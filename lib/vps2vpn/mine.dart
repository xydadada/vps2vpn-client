// vps2vpn "Me": your subscriptions, look and language, and the door to
// advanced mode.

import 'dart:async';
import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/account.dart';
import 'package:fl_clash/vps2vpn/clipboard_import.dart';
import 'package:fl_clash/vps2vpn/flags.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/shell.dart';
import 'package:fl_clash/vps2vpn/subscription_notice.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' show ThemeMode;

/// vps2vpn: strict-route is on by default for the Windows TUN (see
/// withWindowsStrictRoute in lib/common/migration.dart). This switch turns it
/// off for VMs and LAN setups it breaks, keeping the key so the choice sticks.
/// The TUN override page shows the same key in advanced mode.
class _LanCompatibilityRow extends ConsumerWidget {
  const _LanCompatibilityRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strictRoute = ref.watch(
      patchClashConfigProvider.select(
        (state) =>
            state.tunOverrideKeys.contains(TunOverrideKey.strictRoute) &&
            state.tunOverride.strictRoute,
      ),
    );
    return VpsRow(
      icon: VpsIcon.globe,
      title: tr(context, '局域网兼容模式', 'LAN compatibility mode'),
      subtitle: tr(
        context,
        '用虚拟网卡时，虚拟机（VirtualBox、Hyper-V）或局域网里的打印机、NAS 连不上，就打开它。代价是少量请求（域名查询、IPv6）可能不经过你的服务器',
        'Turn on if, with the virtual adapter, VMs (VirtualBox, Hyper-V) or '
            'printers and NAS on your network stop working. Some lookups and '
            'IPv6 traffic may then skip your server',
      ),
      trailing: VpsSwitch(
        value: !strictRoute,
        // A setup-only change: CoreManager's setupPatch listener re-applies.
        onChanged: (compatible) => ref
            .read(patchClashConfigProvider.notifier)
            .update(
              (state) => state.copyWith(
                tunOverride: state.tunOverride.copyWith(
                  strictRoute: !compatible,
                ),
                tunOverrideKeys: {
                  ...state.tunOverrideKeys,
                  TunOverrideKey.strictRoute,
                },
              ),
            ),
      ),
    );
  }
}

class VpsMePage extends ConsumerStatefulWidget {
  const VpsMePage({super.key});

  @override
  ConsumerState<VpsMePage> createState() => _VpsMePageState();
}

class _VpsMePageState extends ConsumerState<VpsMePage> {
  String? _note;
  bool _updating = false;
  bool _pasting = false;

  Future<void> _updateProfiles(List<Profile> profiles) async {
    if (_updating) return;
    final action = ref.read(profilesActionProvider.notifier);
    setState(() => _updating = true);
    try {
      await globalState.batchRun(
        profiles.where((p) => p.type == ProfileType.url).toList(),
        (profile) async {
          final list = mounted
              ? ref.read(profilesProvider)
              : globalState.container.read(profilesProvider);
          final current = list.getProfile(profile.id);
          if (current == null || current.type != ProfileType.url) return;
          await action.updateProfile(current, showLoading: true);
        },
        label: (profile) => profile.realLabel,
        concurrency: 1,
        tag: null,
      );
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _paste() async {
    if (_pasting) return;
    setState(() => _pasting = true);
    try {
      final result = await vpsImportClipboard(ref);
      if (!mounted) return;
      setState(() => _note = vpsImportNote(context, result));
      // Added: the next step is connecting, which lives on Home.
      if (result == VpsImportResult.added) vpsTab.value = vpsTabHome;
    } finally {
      if (mounted) setState(() => _pasting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final profiles = ref.watch(profilesProvider);
    final hasRemoteProfiles = profiles.any((p) => p.type == ProfileType.url);
    final currentId = ref.watch(currentProfileIdProvider);
    final themeMode = ref.watch(
      themeSettingProvider.select((s) => s.themeMode),
    );
    final locale = ref.watch(appSettingProvider.select((s) => s.locale));
    final autoLaunch = ref.watch(
      appSettingProvider.select((s) => s.autoLaunch),
    );
    final advanced = ref.watch(
      appSettingProvider.select((s) => s.advancedMode),
    );
    final smart = ref.watch(appSettingProvider.select((s) => s.smartLines));

    return VpsPage(
      title: tr(context, '设置', 'Settings'),
      subtitle: tr(
        context,
        '订阅、外观与偏好',
        'Subscriptions, appearance and preferences',
      ),
      children: [
        VpsSectionTitle(
          tr(context, '订阅', 'Subscriptions'),
          trailing: !hasRemoteProfiles
              ? null
              : VpsPressable(
                  onTap: _updating ? null : () => _updateProfiles(profiles),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      VpsIconView(VpsIcon.refresh, size: 15, color: p.accent),
                      const SizedBox(width: 5),
                      Text(
                        _updating
                            ? context.appLocalizations.loading
                            : tr(context, '全部更新', 'Update all'),
                        style: vpsText(
                          p,
                          size: 13,
                          weight: FontWeight.w700,
                          color: p.accent,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        const VpsUpdateCard(),
        const VpsAccountCard(),
        for (final profile in profiles)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _ProfileCard(
              profile: profile,
              selected: profile.id == currentId,
              onTap: () => ref.read(currentProfileIdProvider.notifier).value =
                  profile.id,
              onUpdate: _updating ? null : () => _updateProfiles([profile]),
            ),
          ),
        VpsCard(
          highlight: profiles.isEmpty,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                profiles.isEmpty
                    ? tr(context, '导入订阅', 'Import a subscription')
                    : tr(context, '导入更多订阅', 'Import another'),
                style: vpsText(p, size: 14.5, weight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                tr(
                  context,
                  '从剪贴板读取订阅链接，或导入本地配置文件',
                  'Read a link from the clipboard, or import a local config file',
                ),
                style: vpsText(p, size: 13, color: p.soft),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  VpsButton(
                    label: tr(context, '从剪贴板导入', 'From clipboard'),
                    icon: VpsIcon.paste,
                    filled: true,
                    onTap: _pasting ? null : _paste,
                  ),
                  VpsButton(
                    label: tr(context, '本地文件', 'Local file'),
                    icon: VpsIcon.file,
                    onTap: () => ref
                        .read(profilesActionProvider.notifier)
                        .addProfileFormFile(),
                  ),
                ],
              ),
              if (_note != null) ...[
                const SizedBox(height: 10),
                Text(_note!, style: vpsText(p, size: 12.5, color: p.warn)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
        VpsSectionTitle(tr(context, '外观', 'Appearance')),
        VpsCard(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          child: Column(
            children: [
              _ChoiceRow(
                icon: VpsIcon.sun,
                label: tr(context, '主题', 'Theme'),
                child: VpsSegmented<ThemeMode>(
                  items: const [
                    ThemeMode.system,
                    ThemeMode.light,
                    ThemeMode.dark,
                  ],
                  value: themeMode,
                  labelOf: (m) => switch (m) {
                    ThemeMode.system => tr(context, '跟随系统', 'System'),
                    ThemeMode.light => tr(context, '浅色', 'Light'),
                    ThemeMode.dark => tr(context, '深色', 'Dark'),
                  },
                  onChanged: (m) => ref
                      .read(themeSettingProvider.notifier)
                      .update((s) => s.copyWith(themeMode: m)),
                ),
              ),
              Container(height: 1, color: p.line),
              _ChoiceRow(
                icon: VpsIcon.globe,
                label: tr(context, '语言', 'Language'),
                child: VpsSegmented<String?>(
                  items: const [null, 'zh', 'en'],
                  value: locale == null
                      ? null
                      : (locale.startsWith('zh')
                            ? 'zh'
                            : (locale.startsWith('en') ? 'en' : null)),
                  labelOf: (l) => switch (l) {
                    'zh' => '中文',
                    'en' => 'English',
                    _ => tr(context, '跟随系统', 'System'),
                  },
                  onChanged: (l) => ref
                      .read(appSettingProvider.notifier)
                      .update((s) => s.copyWith(locale: l)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        VpsSectionTitle(tr(context, '通用', 'General')),
        VpsCard(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          child: Column(
            children: [
              VpsRow(
                icon: VpsIcon.bolt,
                title: tr(context, '智能线路', 'Smart line'),
                subtitle: tr(
                  context,
                  '自动用最快的服务器，不乱换出口 IP；AI 服务固定出口',
                  'Fastest server, steady exit IP; steady exit for AI',
                ),
                trailing: VpsSwitch(
                  value: smart,
                  onChanged: (v) {
                    ref
                        .read(appSettingProvider.notifier)
                        .update((s) => s.copyWith(smartLines: v));
                    // The groups are built when the profile is applied.
                    ref
                        .read(setupActionProvider.notifier)
                        .applyProfileDebounce(force: true);
                  },
                ),
              ),
              if (system.isDesktop) ...[
                Container(height: 1, color: p.line),
                VpsRow(
                  icon: VpsIcon.shield,
                  title: tr(context, '连接时自动接管', 'Take over on Connect'),
                  subtitle: tr(
                    context,
                    '自动关闭其他代理软件、避开被占用的端口、清理失效的系统代理',
                    'Close other proxy apps, avoid taken ports, clear stale proxies',
                  ),
                  trailing: VpsSwitch(
                    value: ref.watch(
                      appSettingProvider.select((s) => s.takeover),
                    ),
                    onChanged: (v) => ref
                        .read(appSettingProvider.notifier)
                        .update((s) => s.copyWith(takeover: v)),
                  ),
                ),
                if (system.isWindows) ...[
                  Container(height: 1, color: p.line),
                  const _LanCompatibilityRow(),
                ],
                Container(height: 1, color: p.line),
                VpsRow(
                  icon: VpsIcon.sun,
                  title: tr(context, '开机自启', 'Launch at startup'),
                  trailing: VpsSwitch(
                    value: autoLaunch,
                    onChanged: (v) => ref
                        .read(appSettingProvider.notifier)
                        .update((s) => s.copyWith(autoLaunch: v)),
                  ),
                ),
              ],
              Container(height: 1, color: p.line),
              VpsRow(
                icon: VpsIcon.gear,
                title: tr(context, '高级模式', 'Advanced mode'),
                subtitle: tr(
                  context,
                  '显示全部页面与专业设置',
                  'Show every page and expert setting',
                ),
                trailing: VpsSwitch(
                  value: advanced,
                  onChanged: (v) {
                    vps2vpnAdvancedMode = v;
                    ref
                        .read(appSettingProvider.notifier)
                        .update((s) => s.copyWith(advancedMode: v));
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        VpsSectionTitle(tr(context, '共享与工具', 'Sharing & tools')),
        const _ShareTools(),
        const SizedBox(height: 24),
        VpsCard(
          child: Row(
            children: [
              const VpsLogo(size: 44),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(() {
                      try {
                        return 'vps2vpn  v${globalState.packageInfo.version}';
                      } catch (_) {
                        return 'vps2vpn';
                      }
                    }(), style: vpsText(p, size: 15, weight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      tr(context, '你的私有网络客户端', 'Your private network client'),
                      style: vpsText(p, size: 12.5, color: p.soft),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const _LegalLine(),
      ],
    );
  }
}

/// The licence notice the GPL asks for, kept out of the way: one faint line
/// at the very bottom of Settings that opens on tap.
class _LegalLine extends StatefulWidget {
  const _LegalLine();

  @override
  State<_LegalLine> createState() => _LegalLineState();
}

class _LegalLineState extends State<_LegalLine> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final style = vpsText(p, size: 11, color: p.muted, height: 1.6);
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Column(
        children: [
          VpsPressable(
            onTap: () => setState(() => _open = !_open),
            child: Text(tr(context, '许可信息', 'Licences'), style: style),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      tr(
                        context,
                        '本软件包含按 GPL-3.0 许可的开源组件（FlClash、mihomo），以及按 OFL 许可的字体（Inter、Noto Sans SC）。'
                            '全部许可文本位于安装目录 data/legal，可向发布方索取对应源代码。',
                        'Includes GPL-3.0 components (FlClash, mihomo) and OFL fonts '
                            '(Inter, Noto Sans SC). All licences are in data/legal; '
                            'source is available on request.',
                      ),
                      textAlign: TextAlign.center,
                      style: style,
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// LAN sharing, a terminal proxy command and the tray behaviour: what
/// mature clients put one click away.
class _ShareTools extends ConsumerStatefulWidget {
  const _ShareTools();

  @override
  ConsumerState<_ShareTools> createState() => _ShareToolsState();
}

class _ShareToolsState extends ConsumerState<_ShareTools> {
  String? _copied;
  Timer? _copiedTimer;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy(String key, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _copiedTimer?.cancel();
    setState(() => _copied = key);
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _copied == key) setState(() => _copied = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final allowLan = ref.watch(
      patchClashConfigProvider.select((s) => s.allowLan),
    );
    final port = ref.watch(patchClashConfigProvider.select((s) => s.mixedPort));
    final localIp = ref.watch(localIpProvider);
    final tray = ref.watch(appSettingProvider.select((s) => s.minimizeOnExit));
    final proxy = 'http://127.0.0.1:$port';
    final commands = <(String, String)>[
      (
        'PowerShell',
        '\$env:HTTP_PROXY="$proxy"; \$env:HTTPS_PROXY="$proxy"; \$env:ALL_PROXY="$proxy"',
      ),
      (
        'CMD',
        'set "HTTP_PROXY=$proxy" && set "HTTPS_PROXY=$proxy" && set "ALL_PROXY=$proxy"',
      ),
      (
        'Bash',
        'export http_proxy=$proxy https_proxy=$proxy all_proxy=$proxy HTTP_PROXY=$proxy HTTPS_PROXY=$proxy ALL_PROXY=$proxy',
      ),
    ];
    final lanAddress = localIp == null || localIp.isEmpty
        ? null
        : '$localIp:$port';
    return VpsCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Column(
        children: [
          VpsRow(
            icon: VpsIcon.globe,
            title: tr(context, '局域网共享', 'Share on LAN'),
            subtitle: allowLan && lanAddress != null
                ? tr(
                    context,
                    '同一网络的设备填写代理 $lanAddress',
                    'Other devices use proxy $lanAddress',
                  )
                : tr(
                    context,
                    '让同一 Wi-Fi 下的手机、电视等设备也走你的线路',
                    'Let phones and TVs on your Wi-Fi use this line',
                  ),
            trailing: VpsSwitch(
              value: allowLan,
              onChanged: (v) => ref
                  .read(patchClashConfigProvider.notifier)
                  .update((s) => s.copyWith(allowLan: v)),
            ),
          ),
          if (system.isDesktop) ...[
            Container(height: 1, color: p.line),
            VpsRow(
              icon: VpsIcon.file,
              title: tr(context, '终端代理', 'Terminal proxy'),
              subtitle: tr(
                context,
                '复制命令到终端，让 git、npm、pip 等也走代理（本窗口有效）',
                'Paste into a terminal so git, npm, pip use the proxy',
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 0, 0, 14),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (name, cmd) in commands)
                      VpsButton(
                        label: _copied == name
                            ? tr(context, '已复制', 'Copied')
                            : name,
                        icon: VpsIcon.paste,
                        onTap: () => _copy(name, cmd),
                      ),
                  ],
                ),
              ),
            ),
            Container(height: 1, color: p.line),
            VpsRow(
              icon: VpsIcon.shield,
              title: tr(context, '关闭窗口时留在托盘', 'Keep running in tray'),
              subtitle: tr(
                context,
                '点 × 只隐藏窗口，连接不中断',
                'Closing the window keeps the connection',
              ),
              trailing: VpsSwitch(
                value: tray,
                onChanged: (v) => ref
                    .read(appSettingProvider.notifier)
                    .update((s) => s.copyWith(minimizeOnExit: v)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A labelled choice: label on the left, segmented control on the right.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.icon,
    required this.label,
    required this.child,
  });

  final VpsIcon icon;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final head = Row(
      children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: ShapeDecoration(
            color: p.track,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(9),
              side: BorderSide(color: p.line),
            ),
          ),
          child: VpsIconView(icon, size: 17, color: p.soft),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: vpsText(p, size: 14.5, weight: FontWeight.w500),
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      // Narrow windows put the choices under the label, full width.
      child: LayoutBuilder(
        builder: (context, c) => c.maxWidth < 480
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [head, const SizedBox(height: 10), child],
              )
            : Row(
                children: [
                  Expanded(child: head),
                  SizedBox(width: 300, child: child),
                ],
              ),
      ),
    );
  }
}

class _ProfileCard extends ConsumerWidget {
  const _ProfileCard({
    required this.profile,
    required this.selected,
    required this.onTap,
    required this.onUpdate,
  });

  final Profile profile;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onUpdate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = VpsPalette.of(context);
    final sub = profile.subscriptionInfo;
    final used = sub == null ? 0 : sub.upload + sub.download;
    final total = sub?.total ?? 0;
    final ratio = total > 0 ? math.min(1.0, used / total) : 0.0;
    String? expire;
    final d = sub?.expireDate;
    if (d != null) {
      expire = tr(
        context,
        '${d.year}-${_two(d.month)}-${_two(d.day)} 到期',
        'Expires ${d.year}-${_two(d.month)}-${_two(d.day)}',
      );
    }
    final updated = profile.lastUpdateDate;
    return VpsCard(
      onTap: onTap,
      highlight: selected,
      selected: selected,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: ShapeDecoration(
                  color: p.track,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(9),
                    side: BorderSide(color: p.line),
                  ),
                ),
                child: VpsIconView(
                  VpsIcon.servers,
                  size: 17,
                  color: selected ? p.accent : p.soft,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.realLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: vpsText(p, size: 14.5, weight: FontWeight.w600),
                    ),
                    Text(
                      [
                        if (selected) tr(context, '使用中', 'In use'),
                        if (updated != null)
                          tr(
                            context,
                            '${_ago(context, updated)}更新',
                            'updated ${_ago(context, updated)}',
                          ),
                      ].join(' · '),
                      style: vpsText(
                        p,
                        size: 12.5,
                        color: selected ? p.accent : p.soft,
                      ),
                    ),
                  ],
                ),
              ),
              if (profile.url.isNotEmpty)
                VpsPressable(
                  onTap: onUpdate,
                  semanticLabel: context.appLocalizations.update,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: VpsIconView(
                      VpsIcon.refresh,
                      size: 18,
                      color: p.soft,
                    ),
                  ),
                ),
            ],
          ),
          if (total > 0 || expire != null) ...[
            const SizedBox(height: 14),
            if (total > 0)
              ClipRSuperellipse(
                borderRadius: BorderRadius.circular(99),
                child: SizedBox(
                  height: 6,
                  child: Stack(
                    children: [
                      Container(color: p.line),
                      FractionallySizedBox(
                        widthFactor: ratio,
                        child: Container(color: p.accent),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (total > 0)
                  Text(
                    tr(
                      context,
                      '已用 ${used.traffic.show} / ${total.traffic.show}',
                      '${used.traffic.show} of ${total.traffic.show} used',
                    ),
                    style: vpsText(p, size: 12.5, color: p.soft),
                  ),
                const Spacer(),
                if (expire != null)
                  Text(expire, style: vpsText(p, size: 12.5, color: p.soft)),
              ],
            ),
          ],
          if (hasSubscriptionExtras(sub)) ...[
            const SizedBox(height: 14),
            VpsSubscriptionExtras(info: sub),
          ],
        ],
      ),
    );
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

String _ago(BuildContext context, DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return tr(context, '刚刚', 'just now');
  if (d.inHours < 1) {
    return tr(context, '${d.inMinutes} 分钟前', '${d.inMinutes} min ago');
  }
  if (d.inDays < 1) {
    return tr(context, '${d.inHours} 小时前', '${d.inHours} h ago');
  }
  return tr(context, '${d.inDays} 天前', '${d.inDays} d ago');
}
