import 'dart:io';

import 'package:fl_clash/vps2vpn/takeover.dart';
import 'package:flutter_test/flutter_test.dart';

ProcessResult _ok(String out) => ProcessResult(0, 0, out, '');

void main() {
  const tasklist =
      '"System Idle Process","0","Services","0","8 K"\r\n'
      '"FlClash.exe","4120","Console","1","210,000 K"\r\n'
      '"FlClashCore.exe","4188","Console","1","90,000 K"\r\n'
      '"verge-mihomo.exe","5000","Console","1","60,000 K"\r\n'
      '"vps2vpn.exe","6000","Console","1","120,000 K"\r\n'
      '"vps2vpnCore.exe","6010","Console","1","80,000 K"\r\n'
      '"chrome.exe","7000","Console","1","300,000 K"\r\n';

  test('finds other proxy apps and never our own processes', () {
    final rivals = parseRivals(tasklist);
    expect(rivals.map((r) => r.image), [
      'flclash.exe',
      'flclashcore.exe',
      'verge-mihomo.exe',
    ]);
    expect(rivalNames(rivals), ['Clash Verge', 'FlClash']);
  });

  test('knows the newer Clash apps and the bare mihomo builds', () {
    final rivals = parseRivals(
      '"clash-verge-service.exe","100","Services","0","9 K"\r\n'
      '"clash-party.exe","101","Console","1","9 K"\r\n'
      '"mihomo-windows-amd64.exe","102","Console","1","9 K"\r\n',
    );
    expect(rivalNames(rivals), ['Clash Party', 'Clash Verge', 'mihomo']);
  });

  group('who holds the system proxy', () {
    const netstat =
        '\r\nActive Connections\r\n\r\n'
        '  Proto  Local Address          Foreign Address        State           PID\r\n'
        '  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1000\r\n'
        '  TCP    127.0.0.1:17890        0.0.0.0:0              LISTENING       2000\r\n'
        '  TCP    127.0.0.1:7897         0.0.0.0:0              LISTENING       3000\r\n'
        '  TCP    127.0.0.1:7897         127.0.0.1:50000        ESTABLISHED     4000\r\n';

    test('reads the listening PID, never a connection to the port', () {
      expect(parseListeningPid(netstat, 7897), 3000);
      expect(parseListeningPid(netstat, 17890), 2000);
      expect(parseListeningPid(netstat, 7890), isNull);
    });

    test('takes the port only of a proxy on this machine', () {
      VpsSystemProxy proxy(String server, {bool enabled = true}) =>
          VpsSystemProxy(enabled: enabled, server: server);
      expect(loopbackProxyPort(proxy('127.0.0.1:7897')), 7897);
      expect(
        loopbackProxyPort(proxy('http=127.0.0.1:7897;https=127.0.0.1:7897')),
        7897,
      );
      expect(loopbackProxyPort(proxy('10.0.0.2:3128')), isNull);
      expect(
        loopbackProxyPort(proxy('127.0.0.1:7897', enabled: false)),
        isNull,
      );
      expect(loopbackProxyPort(null), isNull);
      expect(loopbackProxyPort(proxy('LOCALHOST:7897')), 7897);
    });

    test('runs a Windows tool from System32, a path as given', () {
      expect(vpsSystemTool('tasklist'), endsWith(r'\System32\tasklist.exe'));
      const app = r'C:\Program Files\vps2vpn\vps2vpn.exe';
      expect(vpsSystemTool(app), app);
      expect(vpsSystemTool('tasklist', windows: false), 'tasklist');
    });

    test('names the owner by its product name, or its image', () async {
      Future<ProcessResult> run(String exe, List<String> args) async {
        if (exe == 'netstat') return _ok(netstat);
        return _ok(
          args[1] == 'PID eq 3000'
              ? '"verge-mihomo.exe","3000","Console","1","9 K"\r\n'
              : '"AirportClient.exe","2000","Console","1","9 K"\r\n',
        );
      }

      expect(await portOwner(7897, run: run), 'Clash Verge');
      expect(await portOwner(17890, run: run), 'AirportClient.exe');
      expect(await portOwner(7890, run: run), isNull);
    });
  });

  group('another VPN', () {
    const routes =
        'Publish  Type      Met  Prefix                    Idx  Gateway/Interface Name\r\n'
        '-------  --------  ---  ------------------------  ---  ------------------------\r\n'
        'No       Manual    0    0.0.0.0/0                   5  192.0.2.1\r\n'
        'No       Manual    0    0.0.0.0/1                  41  198.51.100.2\r\n'
        'No       Manual    0    128.0.0.0/1                41  198.51.100.2\r\n'
        'No       Manual    0    0.0.0.0/0                  52  wgci\r\n'
        'No       System    256  192.0.2.0/24                5  Ethernet\r\n'
        'No       Manual    0    0.0.0.0/1                  60  vps2vpn\r\n';
    const interfaces =
        'Idx     Met         MTU          State                Name\r\n'
        '---  ----------  ----------  ------------  ---------------------------\r\n'
        '  1          75  4294967295  connected     Loopback Pseudo-Interface 1\r\n'
        '  5          25        1500  connected     Ethernet\r\n'
        ' 41           0        9000  connected     other tun\r\n'
        ' 52           5        1420  connected     wgci\r\n'
        ' 60           0        9000  connected     vps2vpn\r\n';

    test('reads the split and gateway-less default routes, not the card', () {
      expect(parseVpnRouteIndexes(routes), {41, 52, 60});
      expect(parseInterfaceNames(interfaces)[41], 'other tun');
    });

    test('names the other VPNs and never our own adapter', () async {
      Future<ProcessResult> run(String exe, List<String> args) async =>
          _ok(args.last == 'route' ? routes : interfaces);
      expect(await scanOtherVpns(ownDevice: 'vps2vpn', run: run), [
        'other tun',
        'wgci',
      ]);
    });

    test('an on-link default route through 0.0.0.0 is a VPN (C11-04)', () {
      expect(
        parseVpnRouteIndexes(
          'No       Manual    0    0.0.0.0/0                  33  0.0.0.0\r\n'
          'No       Manual    0    0.0.0.0/0                   5  192.0.2.1\r\n',
        ),
        {33},
      );
    });

    test('a plain network card is no other VPN', () async {
      Future<ProcessResult> run(String exe, List<String> args) async => _ok(
        args.last == 'route'
            ? 'No       Manual    0    0.0.0.0/0                   5  192.0.2.1\r\n'
            : interfaces,
      );
      expect(await scanOtherVpns(ownDevice: 'vps2vpn', run: run), isEmpty);
    });
  });

  test('ignores lines that are not process rows', () {
    expect(parseRivals('INFO: No tasks are running\r\n'), isEmpty);
    expect(parseRivals(''), isEmpty);
  });

  group('system proxy', () {
    const base =
        'HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\r\n'
        '    DisableCachingOfSSLPages    REG_DWORD    0x0\r\n';

    test('reads a proxy another app left switched on', () {
      final p = parseInternetSettings(
        '$base    ProxyEnable    REG_DWORD    0x1\r\n'
        '    ProxyServer    REG_SZ    127.0.0.1:7897\r\n',
      );
      expect(p.enabled, isTrue);
      expect(p.active, isTrue);
      expect(p.isOurs(7890), isFalse);
      expect(p.isOurs(7897), isTrue);
    });

    test('a switched-off proxy is not active', () {
      final p = parseInternetSettings(
        '$base    ProxyEnable    REG_DWORD    0x0\r\n'
        '    ProxyServer    REG_SZ    127.0.0.1:7890\r\n',
      );
      expect(p.active, isFalse);
      expect(p.isOurs(7890), isFalse);
    });

    test('matches complete active endpoints, never a substring', () {
      for (final server in [
        '127.0.0.1:178900',
        'http=127.0.0.1:17890;https=proxy.example:3128',
        '127.0.0.1:17890.evil.example',
        'http=127.0.0.1:17890',
      ]) {
        expect(
          VpsSystemProxy(enabled: true, server: server).isOurs(17890),
          isFalse,
        );
      }
      for (final server in [
        '127.0.0.1:17890',
        'localhost:17890',
        '[::1]:17890',
        'http=127.0.0.1:17890;https=localhost:17890',
      ]) {
        expect(
          VpsSystemProxy(enabled: true, server: server).isOurs(17890),
          isTrue,
        );
      }
    });

    test('PAC ownership cannot be inferred from the mixed port', () {
      expect(
        const VpsSystemProxy(
          enabled: false,
          pac: 'https://company.example:17890/a.pac',
        ).isOurs(17890),
        isFalse,
      );
    });

    test('a PAC script counts as an active proxy', () {
      final p = parseInternetSettings(
        '$base    ProxyEnable    REG_DWORD    0x0\r\n'
        '    AutoConfigURL    REG_SZ    http://127.0.0.1:33331/pac\r\n',
      );
      expect(p.active, isTrue);
      expect(p.isOurs(7890), isFalse);
    });
  });

  group('port', () {
    test('keeps the preferred port when it is free', () async {
      expect(await pickPort(7890, isFree: (_) async => true), 7890);
    });

    test('moves to our own range when the preferred one is taken', () async {
      final taken = {7890, 17890};
      expect(
        await pickPort(7890, isFree: (p) async => !taken.contains(p)),
        17891,
      );
    });

    test('a real taken port is reported as taken', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      expect(await portFree(server.port), isFalse);
    });
  });

  test('under flutter test the real runner never ends anything', () async {
    // A made-up image, so even a broken guard could not close a real app.
    const fake = VpsRival('vps2vpn-guard-probe.exe', 1, 'Probe');
    expect(await quitRivals(const [fake]), ['Probe']);
  });

  test(
    'quitting targets only observed PIDs and reports what is left',
    () async {
      final calls = <List<String>>[];
      var scans = 0;
      Future<ProcessResult> run(String exe, List<String> args) async {
        calls.add([exe, ...args]);
        if (exe == 'tasklist') {
          scans++;
          // After taskkill only an elevated FlClash core survives.
          return _ok('"FlClashCore.exe","4188","Services","0","9 K"\r\n');
        }
        return _ok('');
      }

      final left = await quitRivals(parseRivals(tasklist), run: run);
      final kills = calls.where((c) => c.first == 'taskkill').toList();
      expect(kills.map((c) => c.last), ['4120', '4188', '5000']);
      expect(
        kills.every(
          (c) => c.contains('/PID') && !c.contains('/IM') && !c.contains('/T'),
        ),
        isTrue,
      );
      expect(scans, 1);
      expect(left, ['FlClash']);
    },
  );

  test('same executable name kills only the scanned PIDs', () async {
    const rivals = [
      VpsRival('flclash.exe', 4120, 'FlClash'),
      VpsRival('flclash.exe', 4130, 'FlClash'),
      VpsRival('flclash.exe', 0, 'FlClash'),
    ];
    final kills = <List<String>>[];
    Future<ProcessResult> run(String exe, List<String> args) async {
      if (exe == 'taskkill') kills.add(args);
      if (exe == 'tasklist') return _ok('');
      return _ok('');
    }

    await quitRivals(rivals, run: run);
    expect(kills.map((args) => args.last), ['4120', '4130']);
    expect(
      kills.every((args) => args.contains('/PID') && !args.contains('/T')),
      isTrue,
    );
  });

  test('cancelling takeover stops pending terminations', () async {
    const rivals = [
      VpsRival('flclash.exe', 4120, 'FlClash'),
      VpsRival('mihomo.exe', 5000, 'mihomo'),
    ];
    var current = true;
    final kills = <List<String>>[];
    Future<ProcessResult> run(String exe, List<String> args) async {
      if (exe == 'taskkill') {
        kills.add(args);
        current = false; // user disconnected during the first termination
      }
      if (exe == 'tasklist') {
        fail('Cancelled operation must not scan after kills');
      }
      return _ok('');
    }

    final left = await quitRivals(rivals, run: run, isCurrent: () => current);
    expect(kills.map((args) => args.last), ['4120']);
    expect(left, ['FlClash', 'mihomo']);

    kills.clear();
    await quitRivals(rivals, run: run, isCurrent: () => false);
    expect(kills, isEmpty);
  });
}
