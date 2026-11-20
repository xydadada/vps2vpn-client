import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const prefix = 'do shell script ';
  const suffix = ' with administrator privileges';
  final paths = [
    '/Applications/Vps2VPN Client.app/Contents/Resources/core',
    '/tmp/owner\'s "VPN"/core',
    r'/tmp/back\slash/$HOME/core',
    '/tmp/line\nbreak\ttab\rreturn/core',
    r'/tmp/" & (do shell script "printf marker") & "/core',
  ];

  for (final path in paths) {
    test('the elevation command is one escaped AppleScript string: ${jsonEncode(path)}', () {
      final script = System.macOSElevationScript(path);
      expect(script, startsWith(prefix));
      expect(script, endsWith(suffix));
      final literal = script.substring(prefix.length, script.length - suffix.length);

      // Apple's documented quote, slash and whitespace escapes are a subset
      // of JSON's string escapes. Decoding must recover the entire shell
      // command, including its independent POSIX quoting, as one value.
      expect(jsonDecode(literal), System.macOSElevationShell(path));
    });
  }

  test('osascript decodes the literal without executing the elevation command', () async {
    for (final path in paths.where((path) => !path.contains('\r'))) {
      final script = System.macOSElevationScript(path);
      final literal = script.substring(prefix.length, script.length - suffix.length);
      final result = await Process.run('osascript', ['-e', 'return $literal']);

      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(
        result.stdout,
        '${System.macOSElevationShell(path)}\n',
      );
    }
  }, skip: !Platform.isMacOS);
}
