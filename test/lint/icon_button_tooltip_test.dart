import 'dart:io';

import 'package:test/test.dart';

import 'sources.dart';

final _iconButton = RegExp(r'\bIconButton(?:\.[A-Za-z_]\w*)?\(');

Iterable<File> _dartFilesIn(String root) sync* {
  final directory = Directory(root);
  if (!directory.existsSync()) {
    fail('$root no longer exists; update this test.');
  }
  for (final entity in listSources(root)) {
    if (entity is File &&
        entity.path.endsWith('.dart') &&
        !entity.path.endsWith('.g.dart') &&
        !entity.path.endsWith('.freezed.dart') &&
        !entity.path.contains('/generated/')) {
      yield entity;
    }
  }
}

String _arguments(String source, int start) {
  var depth = 1;
  var index = start;
  while (index < source.length && depth > 0) {
    if (source[index] == '(') depth++;
    if (source[index] == ')') depth--;
    index++;
  }
  return source.substring(start, index - 1);
}

Iterable<int> _unlabelledOffsets(String source) sync* {
  for (final match in _iconButton.allMatches(source)) {
    final arguments = _arguments(source, match.end);
    if (RegExp(r'\btooltip\s*:').hasMatch(arguments)) continue;
    // An icon slot holding text is already its own visible label.
    if (RegExp(r'icon:\s*Text\(').hasMatch(arguments)) continue;
    yield match.start;
  }
}

void main() {
  test('detects unlabelled plain and named IconButton constructors', () {
    const source = '''
IconButton(onPressed: action, icon: GlyphIcon(glyph))
IconButton.filled(onPressed: action, icon: GlyphIcon(glyph))
''';
    expect(_unlabelledOffsets(source), hasLength(2));
  });

  test('accepts tooltips and visible text without counting button data', () {
    const source = '''
IconButton(tooltip: label, onPressed: action, icon: GlyphIcon(glyph))
IconButton.filled(onPressed: action, icon: Text('A'))
IconButtonData(glyph: glyph)
''';
    expect(_iconButton.allMatches(source), hasLength(2));
    expect(_unlabelledOffsets(source), isEmpty);
  });

  test('every IconButton carries a tooltip', () {
    final unlabelled = <String>[];
    var checked = 0;

    for (final file in [
      for (final root in sourceRoots) ..._dartFilesIn(root),
    ]) {
      final source = file.readAsStringSync();
      checked += _iconButton.allMatches(source).length;
      for (final offset in _unlabelledOffsets(source)) {
        final line = '\n'.allMatches(source.substring(0, offset)).length;
        unlabelled.add(
          '${file.path}:${line + 1} — an icon has no accessible name, so '
          'TalkBack and VoiceOver announce nothing and the desktop build shows '
          'no hover hint.',
        );
      }
    }

    expect(checked, greaterThan(0), reason: 'No icon buttons were inspected');
    expect(unlabelled, isEmpty, reason: unlabelled.join('\n'));
  });
}
