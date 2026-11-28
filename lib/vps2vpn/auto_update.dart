// Client updates: found on GitHub Releases, with a vps2vpn panel's member API
// as a mirror, downloaded and signature-checked in the background, then
// installed with one tap. The install itself is the app's own update path
// (CommonAction.installUpdate): Inno Setup's silent install that relaunches
// the app on Windows, the system package installer on Android.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/release_asset.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:fl_clash/vps2vpn/ui_trace.dart';
import 'package:fl_clash/vps2vpn/update_signing.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' show BannerLevel;
import 'package:url_launcher/url_launcher.dart';

/// How often a running app asks GitHub (and the panel) for a newer client.
const vpsUpdateCheckInterval = Duration(hours: 6);
const vpsUpdateRetryInterval = Duration(minutes: 30);

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
    proxyFirst: panel == null || !vpsSameOrigin(panel, url),
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

/// Reads the installer at [path] and its `.sig` again, hashing the same bytes
/// it counts. A link, a folder or a file changed since the download fails.
Future<bool> vpsInstallerVerified(
  String path, {
  String publicKeyHex = vpsUpdatePublicKeyHex,
}) async {
  final sigPath = '$path.sig';
  for (final entry in [path, sigPath]) {
    final type = await FileSystemEntity.type(entry, followLinks: false);
    if (type != FileSystemEntityType.file) return false;
  }
  try {
    final signature = await File(
      sigPath,
    ).openRead(0, 1024).transform(utf8.decoder).join();
    final (sha256Hex, size) = await Isolate.run(() => _hashFile(path));
    return vpsVerifyUpdate(
      fileName: File(path).uri.pathSegments.last,
      sha256Hex: sha256Hex,
      size: size,
      signatureText: signature,
      publicKeyHex: publicKeyHex,
    );
  } on FileSystemException {
    return false;
  } on FormatException {
    return false;
  }
}

Future<(String, int)> _hashFile(String path) async {
  var size = 0;
  final digest = await sha256
      .bind(
        File(path).openRead().map((chunk) {
          size += chunk.length;
          return chunk;
        }),
      )
      .first;
  return (digest.toString(), size);
}

Future<(String, File)?> vpsReadyInstaller(
  Directory dir,
  String current, {
  String publicKeyHex = vpsUpdatePublicKeyHex,
}) async {
  if (!await dir.exists()) return null;
  (String, File)? best;
  await for (final entry in dir.list(followLinks: false)) {
    if (entry is! File) continue;
    final name = entry.uri.pathSegments.last;
    final version = vpsUpdateFileVersion(name);
    if (!name.endsWith('-setup.exe') ||
        version == null ||
        !vpsVersionNewer(version, current) ||
        (best != null && !vpsVersionNewer(version, best.$1))) {
      continue;
    }
    if (await vpsInstallerVerified(entry.path, publicKeyHex: publicKeyHex)) {
      best = (version, entry);
    }
  }
  return best;
}

Future<void> vpsRestoreUpdate(ProviderContainer container) async {
  final current = vpsAppVersion();
  if (current == null || selfUpdateAsset?.os != ReleaseOs.windows) {
    return clearUpdateDownloads();
  }
  try {
    final dir = Directory(await appPath.updateDirPath);
    final ready = await vpsReadyInstaller(dir, current);
    if (ready == null) return await clearUpdateDownloads();
    final (version, file) = ready;
    final keep = {file.path, '${file.path}.sig'};
    await for (final entry in dir.list(followLinks: false)) {
      if (!keep.contains(entry.path)) await safeDeletePath(entry.path);
    }
    final download = container.read(updateDownloadStateProvider.notifier);
    if (download.value == null) {
      download.value = UpdateReady('v$version', file.path);
    }
  } on FileSystemException catch (error) {
    commonPrint.log(
      'Restoring the update download failed: ${compactError(error)}',
      logLevel: LogLevel.warning,
    );
  }
}

/// Downloads [release] and keeps it only when it carries the
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
}) => _downloadBest(
  ProviderScope.containerOf(ref.context, listen: false),
  [release],
  current: current,
  auto: auto,
);

Future<bool> vpsDownloadUpdate(
  WidgetRef ref,
  List<VpsClientRelease> releases, {
  required String current,
}) => _downloadBest(
  ProviderScope.containerOf(ref.context, listen: false),
  releases,
  current: current,
);

enum _Got { done, refused, failed }

Future<_Got> _downloadUpdate(
  ProviderContainer container,
  VpsClientRelease release, {
  required String current,
  bool auto = false,
  bool last = true,
}) async {
  final url = vpsReleaseInstaller(release);
  if (url == null) {
    final page = vpsReleasePage(release);
    if (!auto && page != null) {
      await launchUrl(page, mode: LaunchMode.externalApplication);
    }
    return page == null ? _Got.failed : _Got.done;
  }
  final install = vpsSelfInstallable(_fileName(url));
  final download = container.read(updateDownloadStateProvider.notifier);
  final tag = 'v${release.version}';
  // One download at a time; a ready older version gives way to this one.
  final pending = download.value;
  if (install && pending is UpdateReady && pending.tag == tag) {
    return _Got.done;
  }
  if (install && pending is UpdateDownloading) {
    // Another download, even one of this version, is no try of this one:
    // it may still fail, and the next check has to be free to try again.
    return _Got.failed;
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
    vpsUiTrace('update downloaded ${release.version}');
    if (install) {
      download.value = UpdateReady(tag, file.path);
      _banner(
        (c) => [
          tr(
            c,
            '新版本 ${release.version} 已下载并校验签名，点这里安装（会自动重启 vps2vpn）',
            'Version ${release.version} is downloaded and its signature '
                'checked. ${vpsClick(start: true)} to install it (vps2vpn restarts)',
          ),
          ?vpsReleaseSummary(release.notes, zh: vpsZh(c)),
        ].join('\n'),
        BannerLevel.success,
        onTap: () => unawaited(
          container.read(commonActionProvider.notifier).installUpdate(),
        ),
      );
      return _Got.done;
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
    return _Got.done;
  } on VpsUpdateRejected catch (e) {
    vpsUiTrace('update refused ${release.version} ${e.reason}');
    if (install) download.value = before;
    if (!last) return _Got.refused;
    _banner(
      (c) => switch (e.reason) {
        'unsigned' => tr(
          c,
          '这个安装包没有签名，已拒绝，没有安装',
          'This installer is not signed; it was refused and not installed',
        ),
        'notNewer' => tr(
          c,
          '下载到的安装包不比当前版本新，已拒绝',
          'The downloaded installer is not newer than this version; refused',
        ),
        _ => tr(
          c,
          '安装包签名不对，可能被篡改，已删除，没有安装',
          "The installer's signature is wrong (it may have been tampered "
              'with); it was deleted and not installed',
        ),
      },
      BannerLevel.warning,
    );
    return _Got.refused;
  } catch (error) {
    vpsUiTrace('update failed ${release.version}');
    if (install) download.value = before;
    commonPrint.log(
      'Client update download failed: ${compactError(error)}',
      logLevel: LogLevel.warning,
    );
    if (!auto && last) {
      _banner(
        (c) => tr(c, '下载失败，请稍后再试', 'The download failed; try again later'),
        BannerLevel.warning,
      );
    }
    return _Got.failed;
  }
}

/// Newest first; one out of reach or failing its signature gives way to the
/// next. False when none could be transferred.
Future<bool> _downloadBest(
  ProviderContainer container,
  List<VpsClientRelease> releases, {
  required String current,
  bool auto = false,
}) async {
  var refused = false;
  for (final (i, release) in releases.indexed) {
    final got = await _downloadUpdate(
      container,
      release,
      current: current,
      auto: auto,
      last: i == releases.length - 1,
    );
    if (got == _Got.done) return true;
    refused = refused || got == _Got.refused;
  }
  return refused;
}

@visibleForTesting
Future<VpsClientRelease?> Function({
  required bool installed,
  int? proxyPort,
  String? proxyAuth,
})
vpsGitHubLookup = vpsLatestGitHubRelease;

enum VpsUpdateStatus { never, checking, latest, available, failed }

class VpsUpdateCheck {
  const VpsUpdateCheck({
    this.status = VpsUpdateStatus.never,
    this.at,
    this.releases = const [],
    this.error,
    this.panelOnly = false,
  });

  final VpsUpdateStatus status;
  final DateTime? at;

  final bool panelOnly;

  /// Newer releases this device can use, newest first.
  final List<VpsClientRelease> releases;
  final String? error;
}

class VpsUpdateCheckNotifier extends Notifier<VpsUpdateCheck> {
  @override
  VpsUpdateCheck build() => const VpsUpdateCheck();

  void set(VpsUpdateCheck value) => state = value;
}

final vpsUpdateCheckProvider =
    NotifierProvider<VpsUpdateCheckNotifier, VpsUpdateCheck>(
      VpsUpdateCheckNotifier.new,
    );

/// GitHub first, where every release is published; a vps2vpn panel is only a
/// mirror. Any subscription, or none, gets updates.
Future<VpsUpdateCheck> _check(
  ProviderContainer container,
  String current,
) async {
  final notifier = container.read(vpsUpdateCheckProvider.notifier);
  final before = container.read(vpsUpdateCheckProvider);
  notifier.set(
    VpsUpdateCheck(
      status: VpsUpdateStatus.checking,
      at: before.at,
      releases: before.releases,
    ),
  );
  final on =
      container.read(isStartProvider) && !container.read(suspendProvider);
  final port = on ? container.read(patchClashConfigProvider).mixedPort : null;
  final auth = on
      ? vpsLocalProxyAuth(container.read(networkSettingProvider).authentication)
      : null;
  final found = <VpsClientRelease>[];
  var answered = false;
  String? error;
  for (final via in [?port, null]) {
    try {
      final release = await vpsGitHubLookup(
        installed: selfUpdateAsset != null,
        proxyPort: via,
        proxyAuth: via == null ? null : auth,
      );
      if (release != null) found.add(release);
      answered = true;
      break;
    } catch (e) {
      error = compactError(e);
      commonPrint.log(
        'GitHub release check failed: $error',
        logLevel: LogLevel.warning,
      );
    }
  }
  final keep = container.listen(vpsMemberProvider, (_, _) {});
  var panelAnswered = false;
  try {
    final result = await container
        .read(vpsMemberProvider.future)
        .timeout(const Duration(seconds: 30));
    panelAnswered = result?.member != null;
    if (result?.member?.client case final client?) found.add(client);
  } catch (_) {
  } finally {
    keep.close();
  }
  final usable = [
    for (final (i, r) in found.indexed)
      if (r.newerThan(current) &&
          (vpsReleaseInstaller(r) != null || vpsReleasePage(r) != null))
        (i, r),
  ];
  usable.sort((a, b) {
    if (vpsVersionNewer(a.$2.version, b.$2.version)) return -1;
    if (vpsVersionNewer(b.$2.version, a.$2.version)) return 1;
    return a.$1 - b.$1;
  });
  final known = answered || panelAnswered;
  final check = VpsUpdateCheck(
    status: usable.isNotEmpty
        ? VpsUpdateStatus.available
        : known
        ? VpsUpdateStatus.latest
        : VpsUpdateStatus.failed,
    at: DateTime.now(),
    releases: [for (final (_, r) in usable) r],
    error: usable.isEmpty && !known ? error ?? 'no answer' : null,
    panelOnly: !answered && panelAnswered,
  );
  notifier.set(check);
  return check;
}

Future<VpsUpdateCheck> vpsCheckForUpdateNow(
  WidgetRef ref, {
  String? currentVersion,
}) async {
  final container = ProviderScope.containerOf(ref.context, listen: false);
  final current = currentVersion ?? vpsAppVersion();
  if (current == null) return container.read(vpsUpdateCheckProvider);
  return _check(container, current);
}

/// An installed build fetches a newer client and offers to install it; a
/// portable copy is told, and fetches it on a tap.
Future<void> vpsAutoUpdateCheck(
  WidgetRef ref, {
  @visibleForTesting String? currentVersion,
}) async {
  if (!ref.read(appSettingProvider).autoCheckUpdate) return;
  final current = currentVersion ?? vpsAppVersion();
  if (current == null) return;
  final container = ProviderScope.containerOf(ref.context, listen: false);
  try {
    final check = await _check(container, current);
    vpsUiTrace(
      'update ${check.status.name} '
      '${check.releases.map((r) => r.version).join(',')}',
    );
    if (check.status != VpsUpdateStatus.available) return;
    final newest = check.releases.first;
    if (!_autoTried.add(newest.version)) return;
    final installable = [
      for (final r in check.releases)
        if (vpsReleaseSelfInstalls(r)) r,
    ];
    if (installable.isEmpty) {
      _banner(
        (c) => tr(
          c,
          '有新版本 ${newest.version}，点这里下载（会先校验签名）',
          'Version ${newest.version} is out. ${vpsClick(start: true)} to download it '
              '(its signature is checked first)',
        ),
        BannerLevel.info,
        onTap: () => unawaited(
          _downloadBest(container, check.releases, current: current),
        ),
      );
      return;
    }
    final settled = await _downloadBest(
      container,
      installable,
      current: current,
      auto: true,
    );
    if (!settled) _autoTried.remove(newest.version);
  } catch (error) {
    commonPrint.log(
      'Client update check failed: ${compactError(error)}',
      logLevel: LogLevel.warning,
    );
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
