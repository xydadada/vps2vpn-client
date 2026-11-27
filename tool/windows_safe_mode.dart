import 'dart:convert';
import 'dart:io';

bool windowsSafeMode(String encodedDefines) {
  var enabled = false;
  if (encodedDefines.isEmpty) {
    return enabled;
  }
  for (final encoded in encodedDefines.split(',')) {
    final define = utf8.decode(base64.decode(encoded));
    if (define.startsWith('SAFE_MODE=')) {
      enabled = define.substring('SAFE_MODE='.length) == 'true';
    }
  }
  return enabled;
}

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln('Expected the encoded Flutter DART_DEFINES argument.');
    exitCode = 64;
    return;
  }
  try {
    stdout.write(windowsSafeMode(arguments.single) ? '1' : '0');
  } on FormatException {
    stderr.writeln('Cannot decode Flutter DART_DEFINES.');
    exitCode = 65;
  }
}
