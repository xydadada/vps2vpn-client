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
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/preferences.dart';
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
  'clash-verge-service.exe': 'Clash Verge',
  'clash-nyanpasu.exe': 'Clash Nyanpasu',
  'mihomo-party.exe': 'Mihomo Party',
  'clash-party.exe': 'Clash Party',
  'sparkle.exe': 'Sparkle',
  'gui.for.clash.exe': 'GUI.for.Clash',
  'gui.for.singbox.exe': 'GUI.for.SingBox',
  'mihomo-windows-amd64.exe': 'mihomo',
  'mihomo-windows-amd64-compatible.exe': 'mihomo',
  'mihomo-windows-amd64-v3.exe': 'mihomo',
  'throne.exe': 'Throne',
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

/// Bare proxy cores: a developer's test, a local service or another app's
/// engine as often as a rival app.
const vpsBareCores = {
  'clash.exe',
  'clash-meta.exe',
  'mihomo.exe',
  'mihomo-windows-amd64.exe',
  'mihomo-windows-amd64-compatible.exe',
  'mihomo-windows-amd64-v3.exe',
  'xray.exe',
  'v2ray.exe',
  'sing-box.exe',
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

/// The rivals to close: every proxy app, and a bare core only when it holds
/// one of [guardedPorts] (the system proxy's, ours) or an app being closed
/// started it. The rest are left running and only named.
({List<VpsRival> close, List<VpsRival> spare}) vpsSortRivals(
  List<VpsRival> rivals, {
  required Map<int, Set<int>> listening,
  required Map<int, int> parents,
  required Set<int> guardedPorts,
}) {
  final apps = {
    for (final r in rivals)
      if (!vpsBareCores.contains(r.image)) r.pid,
  };
  final close = <VpsRival>[];
  final spare = <VpsRival>[];
  for (final r in rivals) {
    final holds = (listening[r.pid] ?? const {}).any(guardedPorts.contains);
    if (!vpsBareCores.contains(r.image) ||
        holds ||
        apps.contains(parents[r.pid])) {
      close.add(r);
    } else {
      spare.add(r);
    }
  }
  return (close: close, spare: spare);
}

/// pid → the TCP ports it listens on, from `netstat -ano -p TCP`.
Map<int, Set<int>> parseListeningPorts(String netstat) {
  final pattern = RegExp(
    r'^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$',
    multiLine: true,
  );
  final ports = <int, Set<int>>{};
  for (final m in pattern.allMatches(netstat)) {
    (ports[int.parse(m[2]!)] ??= {}).add(int.parse(m[1]!));
  }
  return ports;
}

Map<int, int> parseParents(String lines) => {
  for (final m in RegExp(
    r'^\s*(\d+),(\d+)\s*$',
    multiLine: true,
  ).allMatches(lines))
    int.parse(m[1]!): int.parse(m[2]!),
};

Future<({List<VpsRival> close, List<VpsRival> spare})> _sortRivals(
  List<VpsRival> rivals, {
  required int ourPort,
  VpsRun run = _run,
}) async {
  final bare = [
    for (final r in rivals)
      if (vpsBareCores.contains(r.image)) r,
  ];
  var listening = const <int, Set<int>>{};
  var parents = const <int, int>{};
  final guarded = {ourPort, ?loopbackProxyPort(await readSystemProxy())};
  if (bare.isNotEmpty) {
    try {
      final netstat = await run('netstat', ['-ano', '-p', 'TCP']);
      listening = parseListeningPorts('${netstat.stdout}');
      final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final ids = bare.map((r) => 'ProcessId=${r.pid}').join(' or ');
      final script =
          'Get-CimInstance Win32_Process -Filter "$ids" | ForEach-Object '
          '{ "\$(\$_.ProcessId),\$(\$_.ParentProcessId)" }';
      final utf16 = [
        for (final unit in script.codeUnits) ...[unit & 0xff, unit >> 8],
      ];
      final ps = await run(
        '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-EncodedCommand',
          base64Encode(utf16),
        ],
      ).timeout(const Duration(seconds: 8));
      parents = parseParents('${ps.stdout}');
    } catch (_) {}
  }
  return vpsSortRivals(
    rivals,
    listening: listening,
    parents: parents,
    guardedPorts: guarded,
  );
}

typedef VpsTakeoverAnswer = ({bool close, bool remember});

/// Shown by the app (takeover_notice.dart); null leaves the apps running.
Future<VpsTakeoverAnswer?> Function(List<String> names)? vpsAskTakeover;

/// Whether to close [names] now: asks once, until an answer is remembered.
Future<bool> vpsDecideTakeover(
  List<String> names, {
  required Future<bool> Function() asked,
  required Future<VpsTakeoverAnswer?> Function(List<String>)? ask,
  required Future<void> Function(bool close) remember,
}) async {
  if (names.isEmpty || await asked()) return true;
  final answer = ask == null ? null : await ask(names);
  if (answer == null) return false;
  if (answer.remember) await remember(answer.close);
  return answer.close;
}

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
    Process.run(vpsSystemTool(executable, windows: Platform.isWindows), args);

/// Windows tools by their System32 path, so a tasklist.exe or reg.exe in the
/// working directory or earlier on PATH is never run instead. A path, such as
/// this app's own executable, is run as given.
String vpsSystemTool(String tool, {bool windows = true}) {
  if (!windows || tool.contains(RegExp(r'[\\/:]'))) return tool;
  final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  return '$root\\System32\\$tool.exe';
}

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
  // An IPv6 holder ([::1], v6-only [::]) passes the IPv4 binds above.
  for (final address in [
    InternetAddress.loopbackIPv6,
    InternetAddress.anyIPv6,
  ]) {
    try {
      final socket = await ServerSocket.bind(address, port, v6Only: true);
      await socket.close();
    } on SocketException catch (e) {
      if (_noIpv6.contains(e.osError?.errorCode)) continue;
      return false;
    } catch (_) {
      return false;
    }
  }
  return true;
}

const _noIpv6 = {10047, 10049, 97, 99, 47, 49};

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

/// Interface indexes another VPN uses to take all IPv4 traffic, from
/// `netsh interface ipv4 show route`: the split default routes (0.0.0.0/1,
/// 128.0.0.0/1) such tunnels add, or a default route with no gateway (an
/// on-link tunnel). A normal network card's default route has a gateway.
@visibleForTesting
Set<int> parseVpnRouteIndexes(String routes) {
  final row = RegExp(
    r'^\s*\S+\s+\S+\s+\d+\s+(0\.0\.0\.0/[01]|128\.0\.0\.0/1)\s+(\d+)\s+(.+?)\s*$',
  );
  final gateway = RegExp(r'^\d+\.\d+\.\d+\.\d+$');
  final found = <int>{};
  for (final line in routes.split(RegExp(r'\r?\n'))) {
    final m = row.firstMatch(line);
    if (m == null) continue;
    final via = m[3]!;
    final onLink = via == '0.0.0.0';
    if (m[1] == '0.0.0.0/0' && gateway.hasMatch(via) && !onLink) continue;
    found.add(int.parse(m[2]!));
  }
  return found;
}

/// Index → name, from `netsh interface ipv4 show interfaces`.
@visibleForTesting
Map<int, String> parseInterfaceNames(String interfaces) {
  final row = RegExp(r'^\s*(\d+)\s+\d+\s+\d+\s+\S+\s+(.+?)\s*$');
  return {
    for (final line in interfaces.split(RegExp(r'\r?\n')))
      if (row.firstMatch(line) case final m?) int.parse(m[1]!): m[2]!,
  };
}

/// Other VPN adapters holding the whole internet now (another app's TUN,
/// WireGuard, OpenVPN, ...), by name; never [ownDevice]. Our own TUN next to
/// one of them fights it over every route and DNS, so the overview asks the
/// user to turn one off. Empty off Windows or when netsh fails.
Future<List<String>> scanOtherVpns({
  required String ownDevice,
  VpsRun run = _run,
}) async {
  if (!Platform.isWindows && identical(run, _run)) return const [];
  try {
    final routes = await run('netsh', ['interface', 'ipv4', 'show', 'route']);
    if (routes.exitCode != 0) return const [];
    final indexes = parseVpnRouteIndexes('${routes.stdout}');
    if (indexes.isEmpty) return const [];
    final r = await run('netsh', ['interface', 'ipv4', 'show', 'interfaces']);
    if (r.exitCode != 0) return const [];
    final names = parseInterfaceNames('${r.stdout}');
    final own = ownDevice.toLowerCase();
    return {
      for (final i in indexes)
        if (names[i] case final name?)
          if (name.toLowerCase() != own) name,
    }.toList()..sort();
  } catch (_) {
    return const [];
  }
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
    this.respawned = const [],
    this.contender,
    this.otherVpns = const [],
    this.spared = const [],
  });

  /// Other proxy apps seen and left alone (takeover off, or safe mode).
  final List<String> running;

  final List<String> spared;

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

  /// Apps a watchdog, service or autostart started again after a close.
  final List<String> respawned;

  final String? contender;

  /// Another VPN's adapters seen when connecting in TUN mode.
  final List<String> otherVpns;

  bool get isEmpty =>
      running.isEmpty &&
      closed.isEmpty &&
      stillRunning.isEmpty &&
      portTo == null &&
      !clearedProxy &&
      respawned.isEmpty &&
      contender == null &&
      otherVpns.isEmpty &&
      spared.isEmpty;

  VpsTakeoverReport withGuardFindings({
    List<String>? respawned,
    List<String>? stillRunning,
    String? contender,
  }) => VpsTakeoverReport(
    running: running,
    closed: closed,
    stillRunning: stillRunning ?? this.stillRunning,
    portFrom: portFrom,
    portTo: portTo,
    clearedProxy: clearedProxy,
    dryRun: dryRun,
    respawned: respawned ?? this.respawned,
    contender: contender ?? this.contender,
    otherVpns: otherVpns,
    spared: spared,
  );
}

final vpsTakeoverReport = ValueNotifier<VpsTakeoverReport>(
  const VpsTakeoverReport(),
);

Timer? _guard;
int _takeoverRevision = 0;
bool _declined = false;

/// Apps closed a second time during this connection; a third start is a
/// watchdog's, and fighting it would only flap the network.
final _closedAgain = <String>{};

final _contenders = <String, int>{};

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
  _declined = false;
  bool canAct() =>
      ref.mounted &&
      revision == _takeoverRevision &&
      !safeModeBuild &&
      !_declined &&
      ref.read(isStartProvider) &&
      ref.read(appSettingProvider).takeover;
  final sorted = await _sortRivals(
    await scanRivals(),
    ourPort: ref.read(patchClashConfigProvider).mixedPort,
  );
  if (!ref.mounted ||
      revision != _takeoverRevision ||
      !ref.read(isStartProvider)) {
    return;
  }
  final rivals = sorted.close;
  final names = rivalNames(rivals);
  if (canAct() &&
      !await vpsDecideTakeover(
        names,
        asked: preferences.getVpsTakeoverAsked,
        ask: vpsAskTakeover,
        remember: (close) async {
          await preferences.setVpsTakeoverAsked(true);
          if (ref.mounted && !close) {
            ref
                .read(appSettingProvider.notifier)
                .update((s) => s.copyWith(takeover: false));
          }
        },
      )) {
    _declined = true;
  }
  if (!ref.mounted ||
      revision != _takeoverRevision ||
      !ref.read(isStartProvider)) {
    return;
  }
  final act = canAct();
  var still = const <String>[];
  if (act && rivals.isNotEmpty) {
    still = await quitRivals(rivals, isCurrent: canAct);
  }
  int? from;
  int? to;
  var cleared = false;
  // Moving our own port changes nothing of another app's, so it also runs
  // with the takeover off: a held port would leave the Core unable to listen.
  bool canMove() =>
      ref.mounted &&
      revision == _takeoverRevision &&
      !safeModeBuild &&
      ref.read(isStartProvider);
  if (canMove()) {
    final port = ref.read(patchClashConfigProvider).mixedPort;
    final next = await pickPort(port);
    if (canMove() && next != port) {
      from = port;
      to = next;
      ref
          .read(patchClashConfigProvider.notifier)
          .update((s) => s.copyWith(mixedPort: next));
    }
  }
  _closedAgain.clear();
  _contenders.clear();
  if (canAct()) {
    if (!ref.read(networkSettingProvider).systemProxy) {
      cleared = await clearStaleSystemProxy();
    }
  }
  final tun = ref.read(patchClashConfigProvider).tun;
  final otherVpns = tun.enable
      ? await scanOtherVpns(ownDevice: tun.device)
      : const <String>[];
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
    otherVpns: otherVpns,
    spared: rivalNames(sorted.spare),
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
Future<void> vpsScanOnly({required int ourPort}) async {
  if (!Platform.isWindows || _underTest) return;
  final sorted = await _sortRivals(await scanRivals(), ourPort: ourPort);
  final names = rivalNames(sorted.close);
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
    otherVpns: last.otherVpns,
    spared: rivalNames(sorted.spare),
  );
}

Future<List<String>> vpsQuitSorted({required int ourPort}) async {
  final sorted = await _sortRivals(await scanRivals(), ourPort: ourPort);
  return quitRivals(sorted.close);
}

/// While connected: puts our proxy back if another app takes it, closes once
/// more an app that came back, and names what keeps coming back.
void _startGuard(Ref ref) {
  _guard?.cancel();
  final revision = _takeoverRevision;
  bool canAct() =>
      ref.mounted &&
      revision == _takeoverRevision &&
      !safeModeBuild &&
      !_declined &&
      ref.read(appSettingProvider).takeover &&
      ref.read(proxyStateProvider).isStart;
  bool isCurrent() => canAct() && ref.read(proxyStateProvider).systemProxy;
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
    if (reading) return;
    reading = true;
    try {
      await _recheckRivals(
        canAct,
        ourPort: ref.read(patchClashConfigProvider).mixedPort,
      );
      if (!state.systemProxy || !isCurrent()) return;
      final proxy = await readSystemProxy();
      if (!isCurrent()) return;
      final needsRefresh = state.pacScript != null
          ? (proxy == null || !proxy.active || (proxy.pac ?? '').isEmpty)
          : (proxy != null && !proxy.isOurs(state.port));
      if (needsRefresh) {
        await _noteContender(proxy);
        await systemProxyQueue?.refresh(isCurrent: isCurrent);
      }
    } finally {
      reading = false;
    }
  });
}

Future<void> _recheckRivals(
  bool Function() canAct, {
  required int ourPort,
}) async {
  final rivals = (await _sortRivals(
    await scanRivals(),
    ourPort: ourPort,
  )).close;
  if (rivals.isEmpty || !canAct()) return;
  final fresh = [
    for (final r in rivals)
      if (!_closedAgain.contains(r.name)) r,
  ];
  final back = rivalNames([
    for (final r in rivals)
      if (_closedAgain.contains(r.name)) r,
  ]);
  _closedAgain.addAll(rivalNames(fresh));
  final still = await quitRivals(fresh, isCurrent: canAct);
  if (!canAct()) return;
  final last = vpsTakeoverReport.value;
  final respawned = {...last.respawned, ...back}.toList()..sort();
  final stillRunning = {...last.stillRunning, ...still}.toList()..sort();
  if (respawned.length == last.respawned.length &&
      stillRunning.length == last.stillRunning.length) {
    return;
  }
  vpsTakeoverReport.value = last.withGuardFindings(
    respawned: respawned,
    stillRunning: stillRunning,
  );
}

Future<void> _noteContender(VpsSystemProxy? proxy) async {
  final port = loopbackProxyPort(proxy);
  final owner = port == null ? null : await portOwner(port);
  if (owner == null) return;
  final times = _contenders[owner] = (_contenders[owner] ?? 0) + 1;
  if (times == 2) {
    vpsTakeoverReport.value = vpsTakeoverReport.value.withGuardFindings(
      contender: owner,
    );
  }
}

int? loopbackProxyPort(VpsSystemProxy? proxy) {
  if (proxy == null || !proxy.enabled) return null;
  for (final entry in (proxy.server ?? '').split(';')) {
    final hostPort = entry.split('=').last.trim();
    final uri = Uri.tryParse(
      hostPort.contains('://') ? hostPort : 'http://$hostPort',
    );
    if (uri != null &&
        uri.hasPort &&
        const [
          '127.0.0.1',
          'localhost',
          '::1',
        ].contains(uri.host.toLowerCase())) {
      return uri.port;
    }
  }
  return null;
}

int? parseListeningPid(String netstat, int port) {
  final pattern = RegExp(
    r'^\s*TCP\s+(?:127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$',
    multiLine: true,
  );
  for (final m in pattern.allMatches(netstat)) {
    if (int.parse(m[1]!) == port) return int.parse(m[2]!);
  }
  return null;
}

Future<String?> portOwner(int port, {VpsRun run = _run}) async {
  if (!Platform.isWindows && identical(run, _run)) return null;
  try {
    final listening = await run('netstat', ['-ano', '-p', 'TCP']);
    final pid = parseListeningPid('${listening.stdout}', port);
    if (pid == null || pid == 0 || pid == 4) return null;
    final r = await run('tasklist', [
      '/FI',
      'PID eq $pid',
      '/FO',
      'CSV',
      '/NH',
    ]);
    final image = RegExp(
      r'^"([^"]+)"',
      multiLine: true,
    ).firstMatch('${r.stdout}');
    if (image == null) return null;
    return vpsRivalImages[image[1]!.toLowerCase()] ?? image[1];
  } catch (_) {
    return null;
  }
}
