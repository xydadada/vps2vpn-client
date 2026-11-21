// vps2vpn takeover: make "Connect" work on a PC that already runs other
// proxy apps. Before connecting it
//   1. closes the other proxy apps (FlClash, Clash Verge, v2rayN, …), which
//      would otherwise fight over the system proxy, the port and TUN;
//   2. moves off a mixed port that something else still holds;
//   3. in TUN mode, clears a system proxy another app left behind (pointing
//      at a port nobody listens on any more, so every page fails to load).
// While connected in system-proxy mode it puts our proxy back if another app
// takes it. Nothing is uninstalled and no other app's settings are changed.
// The safe-mode build only detects; it never closes or changes anything.

import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/proxy.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Process image (lower case) → the product name people know.
const vpsRivalImages = <String, String>{
  'flclash.exe': 'FlClash',
  'flclashcore.exe': 'FlClash',
  'clash-verge.exe': 'Clash Verge',
  'clash verge.exe': 'Clash Verge',
  'verge-mihomo.exe': 'Clash Verge',
  'verge-mihomo-alpha.exe': 'Clash Verge',
  'clash-nyanpasu.exe': 'Clash Nyanpasu',
  'mihomo-party.exe': 'Mihomo Party',
  'clash for windows.exe': 'Clash for Windows',
  'clash-win64.exe': 'Clash for Windows',
  'clash.exe': 'Clash',
  'clash-meta.exe': 'Clash Meta',
  'mihomo.exe': 'mihomo',
  'v2rayn.exe': 'v2rayN',
  'xray.exe': 'Xray',
  'v2ray.exe': 'V2Ray',
  'nekoray.exe': 'NekoRay',
  'nekobox.exe': 'NekoBox',
  'hiddify.exe': 'Hiddify',
  'hiddifycli.exe': 'Hiddify',
  'sing-box.exe': 'sing-box',
  'karing.exe': 'Karing',
  'shadowsocks.exe': 'Shadowsocks',
  'shadowsocksr.exe': 'ShadowsocksR',
  'netch.exe': 'Netch',
  'v2rayn.desktop.exe': 'v2rayN',
};

/// A running process another proxy app owns.
class VpsRival {
  const VpsRival(this.image, this.pid, this.name);

  final String image;
  final int pid;
  final String name;
}

/// Parses `tasklist /FO CSV /NH`: "image","pid","session","#","mem".
List<VpsRival> parseRivals(String tasklistCsv) {
  final rivals = <VpsRival>[];
  for (final line in tasklistCsv.split(RegExp(r'\r?\n'))) {
    final cells = RegExp(
      r'"([^"]*)"',
    ).allMatches(line).map((m) => m[1]!).toList();
    if (cells.length < 2) continue;
    final image = cells[0].toLowerCase();
    final name = vpsRivalImages[image];
    final pid = int.tryParse(cells[1]);
    if (name == null || pid == null) continue;
    rivals.add(VpsRival(image, pid, name));
  }
  return rivals;
}

/// The distinct product names, in a stable order.
List<String> rivalNames(Iterable<VpsRival> rivals) =>
    {for (final r in rivals) r.name}.toList()..sort();

/// What the WinINet settings say about the system proxy.
class VpsSystemProxy {
  const VpsSystemProxy({required this.enabled, this.server, this.pac});

  final bool enabled;
  final String? server;
  final String? pac;

  /// Some proxy is switched on (a server or a PAC script).
  bool get active => enabled || (pac != null && pac!.isNotEmpty);

  /// Points at our own mixed port on this machine.
  bool isOurs(int port) {
    if (!enabled || (pac != null && pac!.isNotEmpty)) return false;
    final entries = (server ?? '')
        .split(';')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (entries.isEmpty) return false;
    final protocols = <String>{};
    for (final entry in entries) {
      final parts = entry.split('=').map((p) => p.trim()).toList();
      if (parts.length > 2 || parts.last.isEmpty) return false;
      if (parts.length == 2) {
        final scheme = parts.first.toLowerCase();
        if (scheme.isEmpty || !protocols.add(scheme)) return false;
      }
      final hostPort = parts.last;
      final uri = Uri.tryParse(
        hostPort.contains('://') ? hostPort : 'http://$hostPort',
      );
      if (uri == null ||
          uri.userInfo.isNotEmpty ||
          uri.path.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          !uri.hasPort ||
          uri.port != port ||
          !const [
            '127.0.0.1',
            'localhost',
            '::1',
          ].contains(uri.host.toLowerCase())) {
        return false;
      }
    }
    return protocols.isEmpty || protocols.containsAll(const ['http', 'https']);
  }
}

/// Parses `reg query "HKCU\...\Internet Settings"`.
VpsSystemProxy parseInternetSettings(String regOutput) {
  String? value(String name) {
    final m = RegExp(
      '^\\s*$name\\s+REG_\\w+\\s+(.*)\$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(regOutput);
    return m?[1]?.trim();
  }

  final enable = value('ProxyEnable');
  return VpsSystemProxy(
    enabled: enable != null && enable != '0x0' && enable != '0',
    server: value('ProxyServer'),
    pac: value('AutoConfigURL'),
  );
}

typedef VpsRun =
    Future<ProcessResult> Function(String executable, List<String> args);

Future<ProcessResult> _run(String executable, List<String> args) =>
    Process.run(executable, args);

/// Other proxy apps running now. Empty off Windows or when tasklist fails.
Future<List<VpsRival>> scanRivals({VpsRun run = _run}) async {
  // Injected test runners are safe to exercise on non-Windows CI.
  if (!Platform.isWindows && identical(run, _run)) return const [];
  try {
    final r = await run('tasklist', ['/FO', 'CSV', '/NH']);
    if (r.exitCode != 0) return const [];
    return parseRivals('${r.stdout}');
  } catch (_) {
    return const [];
  }
}

/// Ends the given apps' processes. Returns the names still running after.
Future<List<String>> quitRivals(
  List<VpsRival> rivals, {
  VpsRun run = _run,
  bool Function()? isCurrent,
}) async {
  if (rivals.isEmpty) return const [];
  if (_underTest && identical(run, _run)) return rivalNames(rivals);
  bool canKill() => isCurrent == null || isCurrent();
  if (!canKill()) return rivalNames(rivals);
  // Kill ONLY the specific observed processes: /IM would also terminate
  // newly launched or unrelated processes sharing the same executable name.
  for (final pid in {for (final rival in rivals) rival.pid}) {
    if (!canKill()) break; // disconnect/takeover disable cancels pending kills
    if (pid <= 0) continue;
    try {
      // /T would also kill descendants that were never in the observed
      // rival list, including unrelated processes launched by the app.
      await run('taskkill', ['/F', '/PID', '$pid']);
    } catch (_) {}
  }
  if (!canKill()) return rivalNames(rivals);
  // Give Windows a moment to release their ports and TUN adapters.
  await Future<void>.delayed(const Duration(milliseconds: 600));
  return rivalNames(await scanRivals(run: run));
}

Future<VpsSystemProxy?> readSystemProxy({VpsRun run = _run}) async {
  if (!Platform.isWindows) return null;
  try {
    final r = await run('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
    ]);
    if (r.exitCode != 0) return null;
    return parseInternetSettings('${r.stdout}');
  } catch (_) {
    return null;
  }
}

/// True when nothing on this machine holds [port] (loopback or all hosts).
Future<bool> portFree(int port) async {
  for (final address in [
    InternetAddress.loopbackIPv4,
    InternetAddress.anyIPv4,
  ]) {
    try {
      final socket = await ServerSocket.bind(address, port);
      await socket.close();
    } catch (_) {
      return false;
    }
  }
  return true;
}

/// [preferred] when it is free, else the first free port of our own range.
Future<int> pickPort(
  int preferred, {
  Future<bool> Function(int)? isFree,
}) async {
  final free = isFree ?? portFree;
  if (await free(preferred)) return preferred;
  for (var p = 17890; p < 17990; p++) {
    if (p != preferred && await free(p)) return p;
  }
  return preferred;
}

/// What the last takeover found and did, for the overview notice.
class VpsTakeoverReport {
  const VpsTakeoverReport({
    this.running = const [],
    this.closed = const [],
    this.stillRunning = const [],
    this.portFrom,
    this.portTo,
    this.clearedProxy = false,
    this.dryRun = false,
  });

  /// Other proxy apps seen and left alone (takeover off, or safe mode).
  final List<String> running;

  /// Apps closed for this connection.
  final List<String> closed;

  /// Apps that did not close (run as administrator, for example).
  final List<String> stillRunning;
  final int? portFrom;
  final int? portTo;

  /// A system proxy another app left behind was cleared.
  final bool clearedProxy;

  /// Safe-mode build: detection only.
  final bool dryRun;

  bool get isEmpty =>
      running.isEmpty &&
      closed.isEmpty &&
      stillRunning.isEmpty &&
      portTo == null &&
      !clearedProxy;
}

final vpsTakeoverReport = ValueNotifier<VpsTakeoverReport>(
  const VpsTakeoverReport(),
);

Timer? _guard;
int _takeoverRevision = 0;

/// `flutter test` must never close the developer's own proxy apps or touch
/// the real port and system proxy, whatever the test drives.
final bool _underTest = Platform.environment.containsKey('FLUTTER_TEST');

/// Cancels any in-flight takeover work and stops the system-proxy guard.
void vpsCancelTakeover() {
  _takeoverRevision++;
  _guard?.cancel();
  _guard = null;
}

/// Ensures the system-proxy guard is running while connected (for example,
/// after a core restart resume that skips [vpsBeforeConnect]).
void vpsEnsureGuard(Ref ref) {
  if (!Platform.isWindows || _underTest) return;
  if (!ref.mounted || !ref.read(isStartProvider)) return;
  if (_guard == null || !_guard!.isActive) {
    _startGuard(ref);
  }
}

/// Runs before every connect. Safe mode, and takeover switched off, only
/// report what they see; nothing is closed or changed.
Future<void> vpsBeforeConnect(Ref ref) async {
  if (!Platform.isWindows || _underTest) return;
  final revision = ++_takeoverRevision;
  bool canAct() =>
      ref.mounted &&
      revision == _takeoverRevision &&
      !safeModeBuild &&
      ref.read(isStartProvider) &&
      ref.read(appSettingProvider).takeover;
  final rivals = await scanRivals();
  if (!ref.mounted ||
      revision != _takeoverRevision ||
      !ref.read(isStartProvider)) {
    return;
  }
  final act = canAct();
  final names = rivalNames(rivals);
  var still = const <String>[];
  if (act && rivals.isNotEmpty) {
    still = await quitRivals(rivals, isCurrent: canAct);
  }
  int? from;
  int? to;
  var cleared = false;
  if (canAct()) {
    final port = ref.read(patchClashConfigProvider).mixedPort;
    final next = await pickPort(port);
    if (canAct() && next != port) {
      from = port;
      to = next;
      ref
          .read(patchClashConfigProvider.notifier)
          .update((s) => s.copyWith(mixedPort: next));
    }
    if (canAct() && !ref.read(networkSettingProvider).systemProxy) {
      cleared = await clearStaleSystemProxy();
    }
  }
  if (!ref.mounted ||
      revision != _takeoverRevision ||
      !ref.read(isStartProvider)) {
    return;
  }
  vpsTakeoverReport.value = VpsTakeoverReport(
    running: act ? const [] : names,
    closed: act ? names.where((n) => !still.contains(n)).toList() : const [],
    stillRunning: still,
    portFrom: from,
    portTo: to,
    clearedProxy: cleared,
    dryRun: safeModeBuild,
  );
  _startGuard(ref);
}

Future<bool> clearStaleSystemProxy({VpsRun run = _run}) async {
  if (!Platform.isWindows || (_underTest && identical(run, _run))) return false;
  try {
    final result = await run(Platform.resolvedExecutable, [
      '--clear-stale-proxy',
    ]);
    return result.exitCode == 0 &&
        (int.tryParse('${result.stdout}'.trim()) ?? 0) > 0;
  } catch (_) {
    return false;
  }
}

/// Only detects (for the overview notice); never closes anything.
Future<void> vpsScanOnly() async {
  if (!Platform.isWindows || _underTest) return;
  final names = rivalNames(await scanRivals());
  final last = vpsTakeoverReport.value;
  final stillRunning = last.stillRunning.where(names.contains).toList();
  vpsTakeoverReport.value = VpsTakeoverReport(
    running: names.where((n) => !stillRunning.contains(n)).toList(),
    closed: last.closed.where((n) => !names.contains(n)).toList(),
    stillRunning: stillRunning,
    portFrom: last.portFrom,
    portTo: last.portTo,
    clearedProxy: last.clearedProxy,
    dryRun: safeModeBuild,
  );
}

/// While connected in system-proxy mode, puts our proxy back if another
/// app takes it.
void _startGuard(Ref ref) {
  _guard?.cancel();
  final revision = _takeoverRevision;
  bool isCurrent() =>
      ref.mounted &&
      revision == _takeoverRevision &&
      !safeModeBuild &&
      ref.read(appSettingProvider).takeover &&
      ref.read(proxyStateProvider).isStart &&
      ref.read(proxyStateProvider).systemProxy;
  if (safeModeBuild || !ref.read(appSettingProvider).takeover) return;
  var reading = false;
  _guard = Timer.periodic(const Duration(seconds: 20), (timer) async {
    if (!ref.mounted ||
        revision != _takeoverRevision ||
        !ref.read(appSettingProvider).takeover) {
      timer.cancel();
      return;
    }
    final state = ref.read(proxyStateProvider);
    if (!state.isStart) {
      timer.cancel();
      return;
    }
    if (!state.systemProxy || reading) return;
    reading = true;
    try {
      final proxy = await readSystemProxy();
      if (!isCurrent()) return;
      final needsRefresh = state.pacScript != null
          ? (proxy == null || !proxy.active || (proxy.pac ?? '').isEmpty)
          : (proxy != null && !proxy.isOurs(state.port));
      if (needsRefresh) {
        await systemProxyQueue?.refresh(isCurrent: isCurrent);
      }
    } finally {
      reading = false;
    }
  });
}
