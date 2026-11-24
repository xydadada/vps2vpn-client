// Client updates the panel owner published (panel.dart's member API): found
// on the panel, downloaded and signature-checked in the background, then
// installed with one tap. The install itself is the app's own update path
// (CommonAction.installUpdate): Inno Setup's silent install that relaunches
// the app on Windows, the system package installer on Android.

import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/release_asset.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' show BannerLevel;
import 'package:url_launcher/url_launcher.dart';

/// How often a running app asks the panel for a newer client.
const vpsUpdateCheckInterval = Duration(hours: 6);

/// The version this app runs, or null when it cannot tell.
String? vpsAppVersion() {
  try {
    return globalState.packageInfo.version;
  } catch (_) {
    return null;
  }
}

/// Whether this build can install [fileName] by itself: an installed Windows
/// build takes the setup program, Android the APK. A portable Windows copy,
/// macOS and Linux keep the manual download.
bool vpsSelfInstallable(String fileName) {
  final name = fileName.toLowerCase();
  return switch (selfUpdateAsset?.os) {
    ReleaseOs.android => name.endsWith('.apk'),
    ReleaseOs.windows => name.endsWith('-setup.exe'),
    _ => false,
  };
}

String _fileName(Uri url) =>
    url.pathSegments.isEmpty ? '' : url.pathSegments.last;

/// The panel's signed installer for this platform, or null when it has none.
Uri? vpsReleaseInstaller(VpsClientRelease release) =>
    release.installerFor(Platform.operatingSystem);

/// The release page to open instead, when there is no installer to fetch.
Uri? vpsReleasePage(VpsClientRelease release) =>
    release.pageFor(Platform.operatingSystem);

/// Whether this build fetches and installs [release] by itself.
bool vpsReleaseSelfInstalls(VpsClientRelease release) {
  final url = vpsReleaseInstaller(release);
  return url != null && vpsSelfInstallable(_fileName(url));
}

/// Fetches the installer at [url] and keeps it only when it carries the
/// release signature and is newer than [current] (see vpsDownloadRelease).
typedef VpsUpdateFetcher =
    Future<File> Function(
      ProviderContainer container,
      Uri url, {
      required bool install,
      required String current,
      void Function(int received, int total)? onProgress,
    });

Future<File> _fetchUpdate(
  ProviderContainer container,
  Uri url, {
  required bool install,
  required String current,
  void Function(int received, int total)? onProgress,
}) async {
  // The panel's own certificate pins vouch for the panel alone, not for a
  // download it links to on another host.
  final panel = vpsApiBase(container.read(currentProfileProvider)?.url ?? '');
  final pins = panel != null && vpsSameOrigin(panel, url)
      ? await container.read(vpsPanelPinsProvider.future)
      : const <String>{};
  final dir = Directory(
    install ? await appPath.updateDirPath : await appPath.downloadDirPath,
  );
  await dir.create(recursive: true);
  final on =
      container.read(isStartProvider) && !container.read(suspendProvider);
  return vpsDownloadRelease(
    url,
    dir,
    pinnedSha256: pins,
    currentVersion: current,
    onProgress: onProgress,
    proxyPort: on ? container.read(patchClashConfigProvider).mixedPort : null,
    proxyAuth: on
        ? vpsLocalProxyAuth(
            container.read(networkSettingProvider).authentication,
          )
        : null,
  );
}

/// Replaced in tests: the transfer itself.
@visibleForTesting
VpsUpdateFetcher vpsUpdateFetcher = _fetchUpdate;

// Versions fetched automatically in this run: one try each, so a panel that
// serves a broken or unsigned file is not downloaded again every few hours. A
// transfer that failed (offline, the panel unreachable) is tried again on the
// next check.
final _autoTried = <String>{};

@visibleForTesting
void resetVpsAutoUpdate() => _autoTried.clear();

/// Downloads [release] from the panel and keeps it only when it carries the
/// release signature and is newer than [current]. A build that installs by
/// itself gets it as the pending update (the dashboard and the Settings card
/// offer "install"); any other opens the folder for a manual install. When
/// the panel has no installer for this platform, its release page opens in
/// the browser instead: a web page is never treated as an installer.
/// [auto] keeps transfer failures quiet; refusals are always shown, as the
/// owner has to fix them. Returns false only when the transfer failed, so a
/// later try may succeed.
/// The app's container is read throughout: [ref]'s page may be gone.
Future<bool> vpsDownloadPanelUpdate(
  WidgetRef ref,
  VpsClientRelease release, {
  required String current,
  bool auto = false,
}) => _downloadUpdate(
  ProviderScope.containerOf(ref.context, listen: false),
  release,
  current: current,
  auto: auto,
);

Future<bool> _downloadUpdate(
  ProviderContainer container,
  VpsClientRelease release, {
  required String current,
  bool auto = false,
}) async {
  final url = vpsReleaseInstaller(release);
  if (url == null) {
    final page = vpsReleasePage(release);
    if (!auto && page != null) {
      await launchUrl(page, mode: LaunchMode.externalApplication);
    }
    return true;
  }
  final install = vpsSelfInstallable(_fileName(url));
  final download = container.read(updateDownloadStateProvider.notifier);
  final tag = 'v${release.version}';
  // One download at a time; a ready older version gives way to this one.
  final pending = download.value;
  if (install && pending is UpdateReady && pending.tag == tag) return true;
  if (install && pending is UpdateDownloading) {
    // Another download, even one of this version, is no try of this one:
    // it may still fail, and the next check has to be free to try again.
    return false;
  }
  // What a failed download puts back: an update already verified stays
  // installable.
  final before = pending is UpdateReady ? pending : null;
  if (!auto) {
    _banner(
      (c) => tr(c, '正在下载新版本…', 'Downloading the new version…'),
      BannerLevel.info,
    );
  }
  if (install) download.value = UpdateDownloading(tag);
  try {
    var shown = 0;
    final file = await vpsUpdateFetcher(
      container,
      url,
      install: install,
      current: current,
      onProgress: install
          ? (received, total) {
              // One rebuild per percent, not one per chunk.
              final step = total > 0 ? total / 100 : 1 << 20;
              if (received - shown < step && received != total) return;
              shown = received;
              download.value = UpdateDownloading(
                tag,
                received: received,
                total: total,
              );
            }
          : null,
    );
    if (install) {
      download.value = UpdateReady(tag, file.path);
      _banner(
        (c) => tr(
          c,
          '新版本 ${release.version} 已下载并校验签名，点这里安装（会自动重启 vps2vpn）',
          'Version ${release.version} is downloaded and its signature checked. '
              'Tap to install it (vps2vpn restarts)',
        ),
        BannerLevel.success,
        onTap: () => unawaited(
          container.read(commonActionProvider.notifier).installUpdate(),
        ),
      );
      return true;
    }
    _banner(
      (c) => tr(
        c,
        '已下载并校验签名：${file.path}，关闭 vps2vpn 后运行它即可升级',
        'Downloaded and signature checked: ${file.path}. Quit vps2vpn, '
            'then run it to upgrade',
      ),
      BannerLevel.info,
    );
    try {
      await launchUrl(Uri.file(file.parent.path));
    } catch (_) {
      // The banner already names the file.
    }
    return true;
  } on VpsUpdateRejected catch (e) {
    if (install) download.value = before;
    _banner(
      (c) => switch (e.reason) {
        'unsigned' => tr(
          c,
          '这个安装包没有签名，已拒绝。请让管理员把发布页上同名的 .sig 文件一起放到面板上',
          'This installer is not signed and was refused. Ask the owner to '
              'put the matching .sig file from the release on the panel',
        ),
        'notNewer' => tr(
          c,
          '面板提供的安装包不比当前版本新，已拒绝',
          'The installer on the panel is not newer than this version; refused',
        ),
        _ => tr(
          c,
          '安装包签名不对，可能被篡改，已删除。请联系管理员',
          "The installer's signature is wrong (it may have been tampered "
              'with) and it was deleted. Contact the owner',
        ),
      },
      BannerLevel.warning,
    );
    return true;
  } catch (error) {
    if (install) download.value = before;
    commonPrint.log(
      'Client update download failed: ${compactError(error)}',
      logLevel: LogLevel.warning,
    );
    if (!auto) {
      _banner(
        (c) => tr(c, '下载失败，请稍后再试', 'The download failed; try again later'),
        BannerLevel.warning,
      );
    }
    return false;
  }
}

/// Asks the panel for a newer client and, when this build installs by itself,
/// fetches it in the background. Respects the "check for updates" setting.
Future<void> vpsAutoUpdateCheck(
  WidgetRef ref, {
  @visibleForTesting String? currentVersion,
}) async {
  if (!ref.read(appSettingProvider).autoCheckUpdate) return;
  final current = currentVersion ?? vpsAppVersion();
  if (current == null) return;
  final container = ProviderScope.containerOf(ref.context, listen: false);
  // The member provider disposes itself without a listener.
  final keep = container.listen(vpsMemberProvider, (_, _) {});
  try {
    final result = await container
        .read(vpsMemberProvider.future)
        .timeout(const Duration(minutes: 1));
    final release = result?.member?.client;
    if (release == null || !release.newerThan(current)) return;
    if (!vpsReleaseSelfInstalls(release)) return;
    if (!_autoTried.add(release.version)) return;
    final settled = await _downloadUpdate(
      container,
      release,
      current: current,
      auto: true,
    );
    if (!settled) _autoTried.remove(release.version);
  } catch (error) {
    commonPrint.log(
      'Client update check failed: ${compactError(error)}',
      logLevel: LogLevel.warning,
    );
  } finally {
    keep.close();
  }
}

void _banner(
  String Function(BuildContext) text,
  BannerLevel level, {
  VoidCallback? onTap,
}) {
  final context = globalState.navigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  dialogs.showBanner(text(context), level: level, onTap: onTap);
}
