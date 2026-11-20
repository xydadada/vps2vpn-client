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
import 'package:fl_clash/models/models.dart' show ProxyState;
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_api/rust_api.dart' as rust_api;

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
    if (name == null || pid == null || pid <= 0) continue;
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
    final s = (server ?? '').trim().toLowerCase();
    return s == '127.0.0.1:$port' || s == 'localhost:$port';
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
  if ((safeModeBuild || _underTest) && identical(run, _run)) {
    return rivalNames(rivals);
  }
  final seen = <int>{};
  for (final rival in rivals) {
    if (isCurrent?.call() == false) return rivalNames(rivals);
    if (rival.pid <= 0 ||
        rival.pid == pid ||
        !vpsRivalImages.containsKey(rival.image) ||
        !seen.add(rival.pid)) {
      continue;
    }
    try {
      await run('taskkill', [
        '/F',
        '/T',
        '/PID',
        '${rival.pid}',
        '/FI',
        'IMAGENAME eq ${rival.image}',
      ]);
    } catch (_) {}
  }
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
  throw const SocketException('No free local proxy port is available');
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

/// `flutter test` must never close the developer's own proxy apps or touch
/// the real port and system proxy, whatever the test drives.
final bool _underTest = Platform.environment.containsKey('FLUTTER_TEST');

/// Runs before every connect. Safe mode, and takeover switched off, only
/// report what they see; nothing is closed or changed.
Future<void> vpsBeforeConnect(Ref ref, {bool Function()? isCurrent}) async {
  if (!Platform.isWindows || _underTest) return;
  final safe = ref.read(safeModeProvider);
  final act = !safe && ref.read(appSettingProvider).takeover;
  bool current() =>
      ref.mounted &&
      (isCurrent?.call() ?? ref.read(isStartProvider)) &&
      (!act ||
          (!ref.read(safeModeProvider) &&
              ref.read(appSettingProvider).takeover));
  final rivals = await scanRivals();
  if (!current()) return;
  final names = rivalNames(rivals);
  var still = const <String>[];
  if (act && rivals.isNotEmpty) {
    still = await quitRivals(rivals, isCurrent: current);
    if (!current()) return;
  }
  int? from;
  int? to;
  var cleared = false;
  if (act) {
    final port = ref.read(patchClashConfigProvider).mixedPort;
    final next = await pickPort(port);
    if (!current()) return;
    if (next != port) {
      from = port;
      to = next;
      ref
          .read(patchClashConfigProvider.notifier)
          .update((s) => s.copyWith(mixedPort: next));
    }
    // TUN mode sets no system proxy, so one left by a closed app would send
    // every browser to a dead port.
    if (!ref.read(networkSettingProvider).systemProxy) {
      final proxy = await readSystemProxy();
      if (!current()) return;
      if (proxy != null && proxy.active) {
        cleared = await rust_api.stopSystemProxy();
        if (!current()) return;
      }
    }
  }
  vpsTakeoverReport.value = VpsTakeoverReport(
    running: act ? const [] : names,
    closed: act ? names.where((n) => !still.contains(n)).toList() : const [],
    stillRunning: still,
    portFrom: from,
    portTo: to,
    clearedProxy: cleared,
    dryRun: safe,
  );
  _startGuard(ref);
}

/// Only detects (for the overview notice); never closes anything.
Future<void> vpsScanOnly() async {
  if (!Platform.isWindows || _underTest) return;
  final names = rivalNames(await scanRivals());
  final last = vpsTakeoverReport.value;
  vpsTakeoverReport.value = VpsTakeoverReport(
    running: names.where((n) => !last.closed.contains(n)).toList(),
    closed: last.closed,
    stillRunning: last.stillRunning,
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
  if (ref.read(safeModeProvider) || _underTest) return;
  var busy = false;
  late final Timer guard;
  ProxyState? current() =>
      ref.mounted &&
          identical(_guard, guard) &&
          !ref.read(safeModeProvider) &&
          ref.read(appSettingProvider).takeover
      ? ref.read(proxyStateProvider)
      : null;
  guard = Timer.periodic(const Duration(seconds: 20), (timer) async {
    if (current()?.isStart != true) {
      timer.cancel();
      return;
    }
    if (busy) return;
    busy = true;
    try {
      await vpsRestoreSystemProxy(
        current: current,
        apply: (state) async {
          await systemProxyQueue?.apply(state);
        },
      );
    } catch (error) {
      if (kDebugMode) debugPrint('vps2vpn proxy guard: $error');
    } finally {
      busy = false;
    }
  });
  _guard = guard;
  ref.onDispose(guard.cancel);
}

@visibleForTesting
Future<void> vpsRestoreSystemProxy({
  required ProxyState? Function() current,
  required Future<void> Function(ProxyState) apply,
  Future<VpsSystemProxy?> Function() inspect = readSystemProxy,
}) async {
  final state = current();
  if (state == null ||
      !state.isStart ||
      !state.systemProxy ||
      state.pacScript != null) {
    return;
  }
  final proxy = await inspect();
  if (current() != state) return;
  if (proxy != null && !proxy.isOurs(state.port)) await apply(state);
}
