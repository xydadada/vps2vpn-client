// vps2vpn: a silent line may be this computer's own network, or a login page.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/diagnose.dart' show vpsReachesInternet;
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum VpsLocalNet { online, offline, portal, unknown }

final vpsPortalPage = Uri.parse('http://www.msftconnecttest.com/redirect');

typedef VpsNic = ({String name, List<InternetAddress> addresses});

bool vpsHasOwnAddress(List<VpsNic> cards, {String tun = appName}) => cards.any(
  (card) =>
      card.name != tun &&
      card.addresses.any((a) => !a.isLoopback && !a.isLinkLocal),
);

Future<List<VpsNic>> _cards() async => [
  for (final card in await NetworkInterface.list())
    (name: card.name, addresses: card.addresses),
];

/// Under TUN, LocalAccess may be our own adapter swallowing Windows' probe.
VpsLocalNet vpsReadConnectivity(
  String lines, {
  required bool viaTun,
  String tun = appName,
}) {
  final levels = <String>{
    for (final line in const LineSplitter().convert(lines))
      if (line.split('|') case [final name, final level] when name != tun)
        level.trim(),
  };
  if (levels.contains('InternetAccess')) return VpsLocalNet.online;
  if (levels.contains('ConstrainedInternetAccess')) return VpsLocalNet.portal;
  if (levels.contains('LocalAccess')) {
    return viaTun ? VpsLocalNet.unknown : VpsLocalNet.offline;
  }
  return levels.isEmpty ? VpsLocalNet.unknown : VpsLocalNet.offline;
}

const _connectivityScript =
    r'$n = @{}; Get-NetAdapter | ForEach-Object { '
    r"$n[$_.InterfaceGuid.Trim('{}').ToLower()] = $_.Name }; "
    r'$null = [Windows.Networking.Connectivity.NetworkInformation, '
    r'Windows.Networking.Connectivity, ContentType = WindowsRuntime]; '
    r'foreach ($p in [Windows.Networking.Connectivity.NetworkInformation]'
    r'::GetConnectionProfiles()) { $a = $p.NetworkAdapter; if ($a) { '
    r'$k = "$($a.NetworkAdapterId)".ToLower(); if ($n.ContainsKey($k)) { '
    r'"$($n[$k])|$($p.GetNetworkConnectivityLevel())" } } }';

Future<String> _windowsConnectivity() async {
  final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  final utf16 = [
    for (final unit in _connectivityScript.codeUnits) ...[
      unit & 0xff,
      unit >> 8,
    ],
  ];
  final ps = await Process.run(
    '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
    ['-NoProfile', '-NonInteractive', '-EncodedCommand', base64Encode(utf16)],
  ).timeout(const Duration(seconds: 5));
  return '${ps.stdout}';
}

Future<VpsLocalNet> vpsCheckLocalNetwork({
  required bool viaTun,
  Future<List<VpsNic>> Function()? cards,
  Future<String> Function()? connectivity,
  Future<bool> Function()? reaches,
}) async {
  try {
    final list = await (cards ?? _cards)();
    if (!vpsHasOwnAddress(list)) return VpsLocalNet.offline;
  } catch (_) {}
  final ask =
      connectivity ?? (Platform.isWindows ? _windowsConnectivity : null);
  if (ask == null) return VpsLocalNet.unknown;
  final VpsLocalNet verdict;
  try {
    verdict = vpsReadConnectivity(await ask(), viaTun: viaTun);
  } catch (_) {
    return VpsLocalNet.unknown;
  }
  // Without TUN our sockets go straight out, so they can overrule Windows.
  if (verdict == VpsLocalNet.offline &&
      !viaTun &&
      await (reaches ?? vpsReachesInternet)()) {
    return VpsLocalNet.unknown;
  }
  return verdict;
}

final vpsLocalNetProvider = FutureProvider.autoDispose<VpsLocalNet>((
  ref,
) async {
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    return VpsLocalNet.unknown;
  }
  final viaTun = ref.watch(
    patchClashConfigProvider.select((s) => s.tun.enable),
  );
  final verdict = await vpsCheckLocalNetwork(viaTun: viaTun);
  if (verdict == VpsLocalNet.offline || verdict == VpsLocalNet.portal) {
    final again = Timer(const Duration(seconds: 15), ref.invalidateSelf);
    ref.onDispose(again.cancel);
  }
  return verdict;
});
