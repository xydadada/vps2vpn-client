import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/vps2vpn/claude_check.dart';
import 'package:fl_clash/vps2vpn/exit_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const hk = IpInfo(ip: '203.0.113.10', countryCode: 'HK');
  const us = IpInfo(ip: '198.51.100.20', countryCode: 'US');
  const usAgain = IpInfo(ip: '198.51.100.20', countryCode: 'US');
  const other = IpInfo(ip: '192.0.2.30', countryCode: 'US');

  test("Claude's own exit wins over the general one", () {
    expect(
      vpsClaudeExit(hk, {'claude.ai': us, 'api.anthropic.com': usAgain}),
      us,
    );
    expect(vpsClaudeExit(hk, {'claude.ai': us, 'api.anthropic.com': null}), us);
  });

  test('without one Claude exit the general exit stands', () {
    expect(vpsClaudeExit(hk, null), hk);
    expect(vpsClaudeExit(hk, const {}), hk);
    expect(vpsClaudeExit(hk, {'claude.ai': null}), hk);
    expect(
      vpsClaudeExit(hk, {'claude.ai': us, 'api.anthropic.com': other}),
      hk,
    );
  });

  test('one address written two ways is the same address', () {
    expect(vpsSameIp('2001:db8:0:0::1', '2001:DB8::1'), isTrue);
    expect(vpsSameIp('203.0.113.1', '203.0.113.1'), isTrue);
    expect(vpsSameIp('2001:db8::1', '2001:db8::2'), isFalse);
    expect(vpsSameIp('203.0.113.1', '203.0.113.2'), isFalse);
  });

  test('only loopback on our port is this app', () {
    expect(vpsPointsHere('http://127.0.0.1:7890', 7890), isTrue);
    expect(vpsPointsHere('127.0.0.1:7890', 7890), isTrue);
    expect(vpsPointsHere('HTTP://LOCALHOST:7890', 7890), isTrue);
    expect(vpsPointsHere('http://[::1]:7890', 7890), isTrue);
    expect(vpsPointsHere('http://evil.localhost:7890', 7890), isFalse);
    expect(vpsPointsHere('http://127.0.0.1:7891', 7890), isFalse);
    expect(vpsPointsHere('http://198.51.100.1:7890', 7890), isFalse);
  });

  test("the user's environment is read from the registry answer", () {
    const output = '''

HKEY_CURRENT_USER\\Environment
    Path    REG_EXPAND_SZ    %USERPROFILE%\\bin
    http_proxy    REG_SZ    http://127.0.0.1:7890
    TEMP    REG_EXPAND_SZ    %USERPROFILE%\\AppData\\Local\\Temp

''';
    expect(vpsProxyFromRegistry(output), 'http://127.0.0.1:7890');
    expect(
      vpsProxyFromRegistry(
        '    HTTPS_PROXY    REG_SZ    http://127.0.0.1:1\n'
        '    HTTP_PROXY    REG_SZ    http://127.0.0.1:2\n',
      ),
      'http://127.0.0.1:1',
    );
    expect(vpsProxyFromRegistry('    Path    REG_SZ    x\n'), isNull);
  });
}
