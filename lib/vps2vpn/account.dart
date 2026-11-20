// Cards fed by the panel's member API (panel.dart): the account on the
// Settings page and the server's own AI check on the Check page. Both stay
// hidden for subscriptions that are not vps2vpn links.

import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' show BannerLevel;
import 'package:url_launcher/url_launcher.dart';

String _ago(BuildContext context, DateTime at) {
  final d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return tr(context, '刚刚', 'just now');
  if (d.inHours < 1) {
    return tr(context, '${d.inMinutes} 分钟前', '${d.inMinutes} min ago');
  }
  if (d.inDays < 1)
    return tr(context, '${d.inHours} 小时前', '${d.inHours} h ago');
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
                    style: vpsText(
                      context,
                      size: 13.5,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
                if (meta.isNotEmpty)
                  Flexible(
                    child: Text(
                      meta,
                      overflow: TextOverflow.ellipsis,
                      style: vpsText(context, size: 12.5, color: p.muted),
                    ),
                  ),
              ],
            ),
            if (ai.summary.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                ai.summary,
                style: vpsText(context, size: 13, color: p.soft, height: 1.45),
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
    'unreachable' => tr(context, '连不上', 'Unreachable'),
    _ => tr(context, '未知', 'Unknown'),
  };
}

/// Settings page: name, usage against the quota, expiry; or why the
/// account is off, or that the link was replaced.
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
        context,
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
        context,
        p,
        color: p.warn,
        title: tr(context, '订阅链接已更换', 'Your link was replaced'),
        lines: [
          tr(
            context,
            '服务器不再认这个链接了。请向管理员要新链接，复制后点“从剪贴板导入”。',
            'The server no longer knows this link. Ask for the new one, copy it and tap "Import from clipboard".',
          ),
        ],
        action: refresh,
      );
    }
    final m = result.member;
    if (m == null) return const SizedBox.shrink();
    final quota = m.quotaBytes;
    final usage = m.unlimited
        ? tr(
            context,
            '已用 ${m.used.traffic.show} · 不限量',
            'Used ${m.used.traffic.show} · unlimited',
          )
        : tr(
            context,
            '已用 ${m.used.traffic.show} / ${quota.traffic.show}',
            'Used ${m.used.traffic.show} of ${quota.traffic.show}',
          );
    String? expiry;
    if (m.expireAt != null) {
      final diff = m.expireAt!.difference(DateTime.now());
      expiry = diff.isNegative
          ? tr(context, '已到期', 'Expired')
          : diff.inDays == 0
          ? tr(context, '今天到期', 'Expires today')
          : tr(
              context,
              '还剩 ${diff.inDays} 天到期',
              'Expires in ${diff.inDays} days',
            );
    }
    final off = !m.enabled;
    final reason = switch (m.disabledReason) {
      'quota' => tr(context, '流量已用完', 'Data used up'),
      'expired' => tr(context, '已到期', 'Expired'),
      'devices' => tr(
        context,
        '设备过多，暂停一会儿',
        'Paused for a while: too many devices',
      ),
      _ => tr(context, '已被管理员停用', 'Turned off by the owner'),
    };
    return _frame(
      context,
      p,
      color: off ? p.bad : p.good,
      title: m.name.isEmpty ? tr(context, '我的账户', 'My account') : m.name,
      status: off ? reason : tr(context, '正常', 'Active'),
      lines: [usage, ?expiry],
      progress: m.unlimited
          ? null
          : (quota > 0 ? (m.used / quota).clamp(0.0, 1.0) : 1.0),
      action: VpsButton(
        label: state.isLoading ? l10n.loading : l10n.update,
        icon: VpsIcon.refresh,
        onTap: state.isLoading ? null : () => ref.invalidate(vpsMemberProvider),
      ),
    );
  }

  Widget _frame(
    BuildContext context,
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
                    style: vpsText(
                      context,
                      size: 14.5,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
                if (status != null) VpsChip(label: status, color: color),
              ],
            ),
            for (final line in lines) ...[
              const SizedBox(height: 6),
              Text(line, style: vpsText(context, size: 13, color: p.soft)),
            ],
            if (action != null) ...[const SizedBox(height: 10), action],
            if (progress != null) ...[
              const SizedBox(height: 10),
              ClipRSuperellipse(
                borderRadius: BorderRadius.circular(99),
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

String? _appVersion() {
  try {
    return globalState.packageInfo.version;
  } catch (_) {
    return null;
  }
}

/// Settings page: the owner published a newer client on the panel. Opens
/// the download in the browser; never downloads or installs by itself.
class VpsUpdateCard extends ConsumerWidget {
  const VpsUpdateCard({super.key, this.currentVersion});

  /// For tests; the app's own version otherwise.
  final String? currentVersion;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final release = ref.watch(vpsMemberProvider).value?.member?.client;
    final current = currentVersion ?? _appVersion();
    if (release == null || current == null || !release.newerThan(current)) {
      return const SizedBox.shrink();
    }
    final p = VpsPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: VpsCard(
        highlight: true,
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
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
                      '有新版本 ${release.version}',
                      'Version ${release.version} is available',
                    ),
                    style: vpsText(
                      context,
                      size: 14.5,
                      weight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    release.notes ??
                        tr(
                          context,
                          '当前 $current，下载后运行安装包即可升级',
                          'You have $current; run the downloaded installer',
                        ),
                    style: vpsText(
                      context,
                      size: 13,
                      color: p.soft,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            VpsButton(
              label: tr(context, '下载', 'Download'),
              filled: true,
              onTap: () => unawaited(
                _download(
                  context,
                  ref,
                  release.downloadFor(Platform.operatingSystem),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Downloads inside the app with the panel's pinned certificate (a
  /// self-signed panel would trip the browser), then shows the folder.
  /// Falls back to the browser when that does not work.
  Future<void> _download(BuildContext context, WidgetRef ref, Uri url) async {
    dialogs.showBanner(
      tr(context, '正在下载新版本…', 'Downloading the new version…'),
      level: BannerLevel.info,
    );
    try {
      final pins = await ref.read(vpsPanelPinsProvider.future);
      final dir = Directory(await appPath.downloadDirPath);
      await dir.create(recursive: true);
      final file = await vpsDownloadRelease(url, dir, pinnedSha256: pins);
      if (!context.mounted) return;
      dialogs.showBanner(
        tr(
          context,
          '已下载到 ${file.path}，关闭 vps2vpn 后运行它即可升级',
          'Saved to ${file.path}. Quit vps2vpn, then run it to upgrade',
        ),
        level: BannerLevel.info,
      );
      await launchUrl(Uri.file(dir.path));
    } catch (_) {
      if (context.mounted) await _openDownload(context, url);
    }
  }

  Future<void> _openDownload(BuildContext context, Uri url) async {
    try {
      final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!opened && context.mounted) {
        dialogs.showBanner(
          tr(
            context,
            '无法打开下载链接，请手动在浏览器中访问',
            'Could not open the download link',
          ),
          level: BannerLevel.warning,
        );
      }
    } catch (_) {
      if (context.mounted) {
        dialogs.showBanner(
          tr(
            context,
            '无法打开下载链接，请手动在浏览器中访问',
            'Could not open the download link',
          ),
          level: BannerLevel.warning,
        );
      }
    }
  }
}
