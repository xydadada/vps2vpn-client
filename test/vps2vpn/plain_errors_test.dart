import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/vps2vpn/plain_errors.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final zh = loadAppLocalizations(const Locale('zh'));
  final en = loadAppLocalizations(const Locale('en'));

  test('a taken port is named in plain words', () {
    const raw =
        'listen tcp 127.0.0.1:7890: bind: Only one usage of each socket '
        'address (protocol/network address/port) is normally permitted.';
    expect(vpsPlainError(raw, zh), contains('端口被别的软件占着'));
    expect(vpsPlainError(raw, en), contains('port vps2vpn needs is taken'));
  });

  test('an unreadable subscription points at the link', () {
    expect(
      vpsPlainError('yaml: line 3: did not find expected key', zh),
      contains('订阅内容读不懂'),
    );
  });

  test('a clock problem says to fix the time', () {
    expect(
      vpsPlainError('x509: certificate has expired or is not yet valid', en),
      contains('PC clock'),
    );
  });

  test('anything unknown keeps the raw text', () {
    expect(vpsPlainError('something else went wrong', zh), isNull);
  });
}
