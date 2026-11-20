import 'dart:async';
import 'dart:io';

import 'package:fl_clash/models/models.dart' show ProxyState;
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

    test('ownership requires an exact local endpoint and no PAC override', () {
      expect(
        const VpsSystemProxy(
          enabled: true,
          server: 'LOCALHOST:7890',
        ).isOurs(7890),
        isTrue,
      );
      for (final server in [
        '127.0.0.1:78901',
        'notlocalhost:7890',
        'http=127.0.0.1:7890;https=other:7890',
      ]) {
        expect(
          VpsSystemProxy(enabled: true, server: server).isOurs(7890),
          isFalse,
          reason: server,
        );
      }
      expect(
        const VpsSystemProxy(
          enabled: true,
          server: '127.0.0.1:7890',
          pac: 'http://other:7890/pac',
        ).isOurs(7890),
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

    test('rejects an exhausted fallback port range', () async {
      await expectLater(
        pickPort(7890, isFree: (_) async => false),
        throwsA(isA<SocketException>()),
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

  test('quitting targets observed PIDs and checks their images', () async {
    final first = pid + 1001;
    final second = pid + 1002;
    final calls = <List<String>>[];
    Future<ProcessResult> run(String exe, List<String> args) async {
      calls.add([exe, ...args]);
      return _ok(
        exe == 'tasklist'
            ? '"FlClashCore.exe","$second","Services","0","9 K"\r\n'
            : '',
      );
    }

    final left = await quitRivals([
      VpsRival('flclash.exe', first, 'FlClash'),
      VpsRival('flclashcore.exe', second, 'FlClash'),
      VpsRival('flclashcore.exe', second, 'FlClash'),
      VpsRival('flclash.exe', pid, 'FlClash'),
      const VpsRival('flclash.exe', 0, 'FlClash'),
      VpsRival('unrelated.exe', first + 5, 'Other'),
    ], run: run);
    expect(calls, [
      [
        'taskkill',
        '/F',
        '/T',
        '/PID',
        '$first',
        '/FI',
        'IMAGENAME eq flclash.exe',
      ],
      [
        'taskkill',
        '/F',
        '/T',
        '/PID',
        '$second',
        '/FI',
        'IMAGENAME eq flclashcore.exe',
      ],
      ['tasklist', '/FO', 'CSV', '/NH'],
    ]);
    expect(left, ['FlClash']);
  });

  test('a cancelled takeover stops issuing process kills', () async {
    var current = true;
    var calls = 0;
    await quitRivals(
      [
        VpsRival('flclash.exe', pid + 1001, 'FlClash'),
        VpsRival('flclashcore.exe', pid + 1002, 'FlClash'),
      ],
      isCurrent: () => current,
      run: (exe, args) async {
        if (exe == 'taskkill') calls++;
        current = false;
        return _ok('');
      },
    );
    expect(calls, 1);
  });

  group('proxy guard intent', () {
    const running = ProxyState(
      isStart: true,
      systemProxy: true,
      bassDomain: [],
      port: 7890,
    );

    test('does not restore a proxy after a stop during inspection', () async {
      ProxyState? state = running;
      final inspection = Completer<VpsSystemProxy?>();
      final applied = <ProxyState>[];
      final pending = vpsRestoreSystemProxy(
        current: () => state,
        inspect: () => inspection.future,
        apply: (value) async => applied.add(value),
      );
      state = running.copyWith(isStart: false);
      inspection.complete(const VpsSystemProxy(enabled: false));
      await pending;
      expect(applied, isEmpty);
    });

    test('takeover disabled and PAC mode skip manual restoration', () async {
      var inspected = false;
      Future<VpsSystemProxy?> inspect() async {
        inspected = true;
        return const VpsSystemProxy(enabled: false);
      }

      Future<void> apply(ProxyState state) async {
        fail('must not restore a manual proxy');
      }

      await vpsRestoreSystemProxy(
        current: () => null,
        inspect: inspect,
        apply: apply,
      );
      await vpsRestoreSystemProxy(
        current: () =>
            running.copyWith(pacScript: 'function FindProxyForURL() {}'),
        inspect: inspect,
        apply: apply,
      );
      expect(inspected, isFalse);
    });

    test('restores a disabled proxy with a matching stale address', () async {
      final applied = <ProxyState>[];
      await vpsRestoreSystemProxy(
        current: () => running,
        inspect: () async =>
            const VpsSystemProxy(enabled: false, server: '127.0.0.1:7890'),
        apply: (value) async => applied.add(value),
      );
      expect(applied, [running]);
    });
  });
}
