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

  test('proxy ownership requires an exact active loopback endpoint', () {
    for (final endpoint in [
      '127.0.0.1:78901',
      'localhost:78900',
      'evil.test/127.0.0.1:7890',
      'http=127.0.0.1:7890;https=proxy.test:443',
    ]) {
      expect(
        VpsSystemProxy(enabled: true, server: endpoint).isOurs(7890),
        isFalse,
      );
    }
    expect(
      const VpsSystemProxy(
        enabled: true,
        pac: 'https://proxy.test:7890/script.pac',
      ).isOurs(7890),
      isFalse,
    );
    expect(
      const VpsSystemProxy(
        enabled: true,
        server: 'LOCALHOST:7890',
      ).isOurs(7890),
      isTrue,
    );
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

  test('quitting ends observed PIDs and reports what is left', () async {
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
    expect(
      calls.where((c) => c.first == 'taskkill').map((c) => c.last).toList(),
      ['4120', '4188', '5000'],
    );
    expect(
      calls
          .where((c) => c.first == 'taskkill')
          .every((c) => c.contains('/PID')),
      isTrue,
    );
    expect(scans, 1);
    expect(left, ['FlClash']);
  });
}
