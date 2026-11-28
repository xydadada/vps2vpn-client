// Cards fed by the panel's member API (panel.dart): the account on the
// Settings page and the server's own AI check on the Check page. Both stay
// hidden for subscriptions that are not vps2vpn links.

import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/auto_update.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

String _ago(BuildContext context, DateTime at) {
  final d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return tr(context, '刚刚', 'just now');
  if (d.inHours < 1) {
    return tr(context, '${d.inMinutes} 分钟前', '${d.inMinutes} min ago');
  }
  if (d.inDays < 1) {
    return tr(context, '${d.inHours} 小时前', '${d.inHours} h ago');
  }
  return tr(context, '${d.inDays} 天前', '${d.inDays} d ago');
}

const _aiSites = [
  ('claude', 'Claude'),
  ('claude_api', 'Claude API'),
  ('chatgpt', 'ChatGPT'),
  ('gemini', 'Gemini'),
];

/// Check page: what the server sees when it opens the AI sites itself. It
/// tells "my line is fine but the site blocks this server" apart from "my
/// line is down".
class VpsServerAiCard extends ConsumerWidget {
  const VpsServerAiCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ai = ref.watch(vpsMemberProvider).value?.member?.ai;
    if (ai == null) return const SizedBox.shrink();
    final p = VpsPalette.of(context);
    final meta = [
      if (ai.place != null && ai.place!.isNotEmpty) ai.place!,
      if (ai.at != null) _ago(context, ai.at!),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: VpsCard(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                VpsIconView(VpsIcon.servers, size: 17, color: p.soft),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr(context, '服务器视角', 'Seen from your server'),
                    style: vpsText(p, size: 13.5, weight: FontWeight.w600),
                  ),
                ),
                if (meta.isNotEmpty)
                  Flexible(
                    child: Text(
                      meta,
                      overflow: TextOverflow.ellipsis,
                      style: vpsText(p, size: 12.5, color: p.muted),
                    ),
                  ),
              ],
            ),
            if (ai.summary.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                ai.summary,
                style: vpsText(p, size: 13, color: p.soft, height: 1.45),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (key, label) in _aiSites)
                  if (ai.sites[key] != null)
                    VpsChip(
                      label: '$label · ${_siteText(context, ai.sites[key]!)}',
                      color: switch (ai.sites[key]) {
                        'ok' => p.good,
                        'blocked' => p.bad,
                        'unreachable' => p.warn,
                        _ => p.muted,
                      },
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _siteText(BuildContext context, String s) => switch (s) {
    'ok' => tr(context, '可用', 'OK'),
    'blocked' => tr(context, '封锁', 'Blocked'),
    'unreachable' => tr(context, '无法连接', 'Unreachable'),
    _ => tr(context, '未知', 'Unknown'),
  };
}

/// Settings page: name, usage against the quota, expiry; or why the
/// account is off, or that the link was replaced.
/// Why the panel will not carry this member's traffic now, or null.
enum VpsAccountBlock { linkChanged, quota, expired, devices, manual }

VpsAccountBlock? vpsAccountBlock(VpsMemberResult? result) {
  if (result == null) return null;
  if (result.linkChanged) return VpsAccountBlock.linkChanged;
  final m = result.member;
  if (m == null || m.enabled) return null;
  return switch (m.disabledReason) {
    'quota' => VpsAccountBlock.quota,
    'expired' => VpsAccountBlock.expired,
    'devices' => VpsAccountBlock.devices,
    _ => VpsAccountBlock.manual,
  };
}

String _slowedHint(BuildContext context, double mbps) {
  final speed = mbps.toStringAsFixed(mbps % 1 == 0 ? 0 : 1);
  return mbps > 0
      ? tr(
          context,
          '流量已用完，当前限速 $speed Mbps，重置或续费后恢复',
          'Data used up: held to $speed Mbps until it resets or you top up',
        )
      : tr(
          context,
          '流量已用完，网速受限，重置或续费后恢复',
          'Data used up: speed is limited until it resets or you top up',
        );
}

String vpsAccountBlockReason(BuildContext context, VpsAccountBlock block) =>
    switch (block) {
      VpsAccountBlock.linkChanged => tr(
        context,
        '订阅链接已失效',
        'Your link no longer works',
      ),
      VpsAccountBlock.quota => tr(context, '流量已用完', 'Data used up'),
      VpsAccountBlock.expired => tr(context, '已到期', 'Expired'),
      VpsAccountBlock.devices => tr(
        context,
        '设备过多，暂停一会儿',
        'Paused for a while: too many devices',
      ),
      VpsAccountBlock.manual => tr(
        context,
        '已被管理员停用',
        'Turned off by the owner',
      ),
    };

/// What the member can do about [block].
String vpsAccountBlockHint(BuildContext context, VpsAccountBlock block) =>
    switch (block) {
      VpsAccountBlock.linkChanged => tr(
        context,
        '请向管理员获取新链接，复制后在「设置」中点击「从剪贴板粘贴」。',
        'Ask the admin for the new link, copy it and ${vpsClick()} '
            '"Paste from clipboard" in Settings.',
      ),
      VpsAccountBlock.devices => tr(
        context,
        '先断开其他设备上的连接，稍后会自动恢复。',
        'Disconnect your other devices; it resumes by itself shortly.',
      ),
      _ => tr(
        context,
        '现在连接也上不了网，请联系管理员处理。',
        "Connecting won't get you online now. Ask the owner to sort it out.",
      ),
    };

/// "Expired", "Expires today" or the whole days left until [expire].
String vpsExpiryText(BuildContext context, DateTime expire, {DateTime? now}) {
  final diff = expire.difference(now ?? DateTime.now());
  if (diff.isNegative) return tr(context, '已到期', 'Expired');
  if (diff.inDays == 0) return tr(context, '今天到期', 'Expires today');
  return tr(context, '还剩 ${diff.inDays} 天', '${diff.inDays} days left');
}

String vpsDayExpiryText(
  BuildContext context,
  VpsDay day, {
  bool withDate = false,
  DateTime? now,
}) {
  final date = day.date;
  if (date == null) return tr(context, '长期有效', 'Never expires');
  final today = now ?? DateTime.now();
  final days = DateTime.utc(
    date.year,
    date.month,
    date.day,
  ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
  if (days < 0) return tr(context, '已到期', 'Expired');
  if (days == 0) return tr(context, '今天到期', 'Expires today');
  if (!withDate) return tr(context, '还剩 $days 天', '$days days left');
  return tr(
    context,
    '还剩 $days 天 · ${vpsDateText(context, date, now: today)}到期',
    '$days days left · until ${vpsDateText(context, date, now: today)}',
  );
}

String vpsResetText(BuildContext context, VpsDay day) => switch (day.date) {
  null => tr(context, '不按月重置', 'No monthly reset'),
  final d => tr(
    context,
    '${vpsDateText(context, d)}重置流量',
    'Data resets on ${vpsDateText(context, d)}',
  ),
};

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

extension VpsTrafficText on TrafficShow {
  /// "15.3 GB": a space between the number and its unit, as everywhere here.
  String get spaced => '$value $unit';
}

/// "11月26日" or "Nov 26" this year, with the year added for any other.
String vpsDateText(BuildContext context, DateTime d, {DateTime? now}) {
  final thisYear = d.year == (now ?? DateTime.now()).year;
  return tr(
    context,
    thisYear ? '${d.month}月${d.day}日' : '${d.year}年${d.month}月${d.day}日',
    thisYear
        ? '${_months[d.month - 1]} ${d.day}'
        : '${_months[d.month - 1]} ${d.day}, ${d.year}',
  );
}

/// The panel's own calendar day first; a timestamp read in this computer's
/// time zone may land a day early.
String? vpsMemberExpiryText(
  BuildContext context,
  VpsMember m, {
  bool withDate = false,
}) => m.expireDay != null
    ? vpsDayExpiryText(context, m.expireDay!, withDate: withDate)
    : m.expireAt != null
    ? vpsExpiryText(context, m.expireAt!)
    : null;

DateTime? vpsMemberExpiryDate(VpsMember m) =>
    m.expireDay != null ? m.expireDay!.date : m.expireAt;

class VpsAccountCard extends ConsumerWidget {
  const VpsAccountCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(vpsMemberProvider);
    final result = state.value;
    if (result == null) return const SizedBox.shrink();
    final p = VpsPalette.of(context);
    final l10n = context.appLocalizations;
    final refresh = VpsButton(
      label: state.isLoading ? l10n.loading : l10n.retry,
      icon: VpsIcon.refresh,
      onTap: state.isLoading ? null : () => ref.invalidate(vpsMemberProvider),
    );
    if (result.problem case final problem?) {
      return _frame(
        p,
        color: p.warn,
        title: l10n.account,
        status: l10n.serviceUnavailable,
        lines: switch (problem) {
          VpsPanelProblem.unavailable => const [],
          VpsPanelProblem.httpsRequired => [l10n.networkTlsError],
          VpsPanelProblem.unreachable => [l10n.networkConnectionError],
        },
        action: refresh,
      );
    }
    if (result.linkChanged) {
      return _frame(
        p,
        color: p.warn,
        title: tr(context, '订阅链接已更换', 'Your link was replaced'),
        lines: [
          tr(
            context,
            '服务器已不再接受这个链接。请向管理员获取新链接，复制后点击「从剪贴板粘贴」。',
            'The server no longer accepts this link. Ask the admin for the '
                'new one, copy it and ${vpsClick()} "Paste from clipboard".',
          ),
        ],
        action: refresh,
      );
    }
    final m = result.member;
    if (m == null) return const SizedBox.shrink();
    final quota = m.quotaGb > 0 ? (m.quotaGb * 1024 * 1024 * 1024).round() : 0;
    final usage = m.unlimited
        ? tr(
            context,
            '已用 ${m.used.traffic.spaced} · 不限量',
            'Used ${m.used.traffic.spaced} · unlimited',
          )
        : tr(
            context,
            '已用 ${m.used.traffic.spaced} / ${quota.traffic.spaced}',
            'Used ${m.used.traffic.spaced} of ${quota.traffic.spaced}',
          );
    final expiry = vpsMemberExpiryText(context, m, withDate: true);
    final reset = m.nextResetDay == null
        ? null
        : vpsResetText(context, m.nextResetDay!);
    final block = vpsAccountBlock(result);
    final slowed = block == null && m.throttled;
    final page = vpsMemberPage(
      ref.watch(currentProfileProvider.select((p) => p?.url ?? '')),
    );
    return _frame(
      p,
      color: block != null
          ? p.bad
          : slowed
          ? p.warn
          : p.good,
      title: m.name.isEmpty ? tr(context, '我的账号', 'My account') : m.name,
      status: block != null
          ? vpsAccountBlockReason(context, block)
          : slowed
          ? tr(context, '已降速', 'Slowed down')
          : tr(context, '正常', 'Normal'),
      lines: [
        usage,
        ?expiry,
        ?reset,
        if (block != null) vpsAccountBlockHint(context, block),
        if (slowed) _slowedHint(context, m.limitMbps),
      ],
      progress: m.unlimited
          ? null
          : (quota > 0 ? (m.used / quota).clamp(0.0, 1.0) : 1.0),
      action: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          VpsButton(
            label: state.isLoading ? l10n.loading : l10n.update,
            icon: VpsIcon.refresh,
            onTap: state.isLoading
                ? null
                : () => ref.invalidate(vpsMemberProvider),
          ),
          // Asking for more data and inviting a friend live on the panel's
          // member centre; open it in the browser.
          if (page != null)
            VpsButton(
              key: const ValueKey('vps-member-centre'),
              label: tr(context, '打开会员中心', 'Open member center'),
              icon: VpsIcon.me,
              filled:
                  block == VpsAccountBlock.quota ||
                  block == VpsAccountBlock.expired,
              onTap: () => unawaited(
                launchUrl(page, mode: LaunchMode.externalApplication),
              ),
            ),
        ],
      ),
    );
  }

  Widget _frame(
    VpsPalette p, {
    required Color color,
    required String title,
    String? status,
    List<String> lines = const [],
    double? progress,
    Widget? action,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: VpsCard(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: vpsText(p, size: 14.5, weight: FontWeight.w600),
                  ),
                ),
                if (status != null) VpsChip(label: status, color: color),
              ],
            ),
            for (final line in lines) ...[
              const SizedBox(height: 6),
              Text(line, style: vpsText(p, size: 13, color: p.soft)),
            ],
            if (action != null) ...[const SizedBox(height: 10), action],
            if (progress != null) ...[
              const SizedBox(height: 10),
              ClipRSuperellipse(
                borderRadius: BorderRadius.circular(VpsRadius.pill),
                child: SizedBox(
                  height: 6,
                  child: Stack(
                    children: [
                      Container(color: p.line),
                      FractionallySizedBox(
                        widthFactor: progress,
                        child: Container(
                          color: progress > 0.9 ? p.warn : p.accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Home, while a verified update waits: a banner shown to a window hidden in
/// the tray is gone by the time the user looks.
class VpsUpdateNotice extends ConsumerWidget {
  const VpsUpdateNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final download = ref.watch(updateDownloadStateProvider);
    if (download is! UpdateReady) return const SizedBox.shrink();
    final version = vpsReadyUpdateVersion(download);
    if (version == null) return const SizedBox.shrink();
    final notes = ref
        .watch(vpsUpdateCheckProvider)
        .releases
        .where((r) => r.version == version)
        .firstOrNull
        ?.notes;
    final summary = vpsReleaseSummary(notes, zh: vpsZh(context));
    final p = VpsPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: VpsCard(
        highlight: true,
        padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
        child: Row(
          children: [
            VpsIconView(VpsIcon.sparkle, size: 19, color: p.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(
                      context,
                      '新版本 $version 已下载并校验签名',
                      'Version $version is downloaded and its signature checked',
                    ),
                    style: vpsText(p, size: 14, weight: FontWeight.w600),
                  ),
                  if (summary != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: vpsText(p, size: 12.5, color: p.soft, height: 1.4),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            VpsButton(
              label: tr(context, '安装并重启', 'Install & restart'),
              filled: true,
              onTap: () => unawaited(
                ref.read(commonActionProvider.notifier).installUpdate(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "15:00" today, "11月26日 15:00" or "Nov 26 15:00" on any other day.
String vpsDateTimeText(BuildContext context, DateTime at, {DateTime? now}) {
  final today = now ?? DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(at.hour)}:${two(at.minute)}';
  if (at.year == today.year && at.month == today.month && at.day == today.day) {
    return time;
  }
  return '${vpsDateText(context, at, now: today)} $time';
}

/// Settings page, always shown: this version, the last check and what it
/// found, and the way to the newer client when there is one, from GitHub or
/// from the panel's mirror.
class VpsUpdateCard extends ConsumerWidget {
  const VpsUpdateCard({super.key, this.currentVersion});

  /// For tests; the app's own version otherwise.
  final String? currentVersion;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = currentVersion ?? vpsAppVersion();
    final check = ref.watch(vpsUpdateCheckProvider);
    final mirror = ref.watch(vpsMemberProvider).value?.member?.client;
    final download = ref.watch(updateDownloadStateProvider);
    final auto = ref.watch(appSettingProvider.select((s) => s.autoCheckUpdate));
    final offers = [
      ...check.releases,
      if (mirror != null &&
          current != null &&
          vpsVersionNewer(vpsReleaseVersion(mirror), current) &&
          (vpsReleaseInstaller(mirror) != null ||
              vpsReleasePage(mirror) != null) &&
          !check.releases.any(
            (r) => vpsReleaseVersion(r) == vpsReleaseVersion(mirror),
          ))
        mirror,
    ];
    final release = offers.fold<VpsClientRelease?>(
      null,
      (best, r) =>
          best == null ||
              vpsVersionNewer(vpsReleaseVersion(r), vpsReleaseVersion(best))
          ? r
          : best,
    );
    final offeredVersion = release == null ? null : vpsReleaseVersion(release);
    final cachedVersion = download is UpdateReady
        ? vpsReadyUpdateVersion(download)
        : null;
    final ready =
        cachedVersion != null &&
        (offeredVersion == null ||
            !vpsVersionNewer(offeredVersion, cachedVersion));
    final availableVersion = ready ? cachedVersion : offeredVersion;
    final p = VpsPalette.of(context);
    final version = current ?? tr(context, '未知', 'unknown');
    final at = check.at == null ? null : vpsDateTimeText(context, check.at!);
    final Widget action;
    final String title;
    final String detail;
    if (availableVersion != null) {
      final ordered = [
        ?release,
        for (final r in offers)
          if (!identical(r, release)) r,
      ];
      final installer = release == null ? null : vpsReleaseInstaller(release);
      final installs =
          ready || release != null && vpsReleaseSelfInstalls(release);
      final busy = download is UpdateDownloading;
      final percent = download is UpdateDownloading && download.total > 0
          ? ' ${(download.received * 100 ~/ download.total).clamp(0, 100)}%'
          : '';
      title = tr(
        context,
        '有新版本 $availableVersion',
        'Version $availableVersion is available',
      );
      detail = installs
          ? tr(
              context,
              '当前 $version，更新会自动安装并重启 vps2vpn',
              'Current: $version; the update installs itself and '
                  'restarts vps2vpn',
            )
          : installer == null
          ? tr(
              context,
              '当前 $version，在下载页获取新版本',
              'Current: $version; get it from the download page',
            )
          : tr(
              context,
              '当前 $version，下载并校验签名后会打开所在文件夹',
              'Current: $version; it is downloaded, its signature '
                  'checked, and its folder opened',
            );
      action = VpsButton(
        label: ready
            ? tr(context, '安装并重启', 'Install & restart')
            : busy
            ? tr(context, '下载中$percent', 'Downloading$percent')
            : installs
            ? tr(context, '更新', 'Update')
            : installer == null
            ? tr(context, '打开下载页', 'Open download page')
            : tr(context, '下载', 'Download'),
        filled: true,
        onTap: ready
            ? () => unawaited(
                ref.read(commonActionProvider.notifier).installUpdate(),
              )
            : busy || current == null
            ? null
            : () =>
                  unawaited(vpsDownloadUpdate(ref, ordered, current: current)),
      );
    } else {
      title = tr(context, '版本与更新', 'Version and updates');
      final status = switch (check.status) {
        VpsUpdateStatus.checking => tr(context, '检查中…', 'Checking…'),
        VpsUpdateStatus.latest when check.panelOnly => tr(
          context,
          '已是最新（$at 检查；暂时无法连接 GitHub，已从订阅服务器确认）',
          'Up to date (checked $at; GitHub was out of reach, the '
              'subscription server confirmed it)',
        ),
        VpsUpdateStatus.latest => tr(
          context,
          '已是最新（$at 检查）',
          'Up to date (checked $at)',
        ),
        VpsUpdateStatus.failed => tr(
          context,
          '检查失败（$at）：无法连接 GitHub，稍后会重试',
          'Check failed ($at): GitHub could not be reached; it is tried '
              'again later',
        ),
        _ =>
          auto
              ? tr(
                  context,
                  '还没检查过，启动后会自动检查',
                  'Not checked yet; it checks shortly after start',
                )
              : tr(context, '自动检查已关闭', 'Automatic checks are off'),
      };
      detail = status;
      final checking = check.status == VpsUpdateStatus.checking;
      action = VpsButton(
        label: checking
            ? tr(context, '检查中…', 'Checking…')
            : tr(context, '检查更新', 'Check for updates'),
        onTap: checking || current == null
            ? null
            : () =>
                  unawaited(vpsCheckForUpdateNow(ref, currentVersion: current)),
      );
    }
    final details = release?.version == availableVersion ? release : null;
    final summary = vpsReleaseSummary(details?.notes, zh: vpsZh(context));
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: VpsCard(
        highlight: availableVersion != null,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            VpsRow(
              icon: availableVersion != null
                  ? VpsIcon.sparkle
                  : VpsIcon.refresh,
              title: title,
              subtitle: detail,
              trailing: action,
            ),
            if (summary != null)
              VpsPressable(
                semanticLabel: tr(context, '更新内容', "What's new"),
                onTap: () => unawaited(
                  dialogs.showAlert(
                    title: tr(
                      context,
                      '${details!.version} 更新内容',
                      "What's new in ${details.version}",
                    ),
                    message: TextSpan(text: details.notes),
                    confirmText: tr(context, '知道了', 'Got it'),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: 48,
                    bottom: 12,
                  ),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: summary),
                        const WidgetSpan(child: SizedBox(width: 8)),
                        TextSpan(
                          text: tr(context, '查看全部', 'See all'),
                          style: TextStyle(color: p.accent),
                        ),
                      ],
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: vpsText(p, size: 13, color: p.soft, height: 1.45),
                  ),
                ),
              ),
            Container(height: 1, color: p.line),
            VpsRow(
              icon: VpsIcon.arrowDown,
              title: tr(context, '自动检查更新', 'Check for updates automatically'),
              trailing: VpsSwitch(
                value: auto,
                onChanged: (v) => ref
                    .read(appSettingProvider.notifier)
                    .update((s) => s.copyWith(autoCheckUpdate: v)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
