import 'package:fl_clash/common/yaml.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

String _aliasBomb(int layers) {
  final out = StringBuffer('l0: &l0 [x, x]\n');
  for (var i = 1; i <= layers; i++) {
    out.writeln('l$i: &l$i [*l${i - 1}, *l${i - 1}]');
  }
  return out.toString();
}

void main() {
  test('aliases and merge keys still read as mihomo reads them', () {
    final doc = loadPlainYaml('''
base: &base {type: ss, port: 443}
proxies:
  - {<<: *base, name: a}
  - {<<: *base, name: b, port: 8443}
same: *base
''');
    expect(doc, {
      'base': {'type': 'ss', 'port': 443},
      'proxies': [
        {'name': 'a', 'type': 'ss', 'port': 443},
        {'name': 'b', 'port': 8443, 'type': 'ss'},
      ],
      'same': {'type': 'ss', 'port': 443},
    });
  });

  test('nested aliases that would expand past the budget are refused', () {
    final bomb = _aliasBomb(24);
    expect(bomb.length, lessThan(1000));
    expect(() => loadPlainYaml(bomb), throwsFormatException);
    expect(loadPlainYaml(_aliasBomb(4)), isA<Map>());
  });

  test('a document nested past the depth limit is refused', () {
    final deep =
        '${'[' * (maxPlainYamlDepth + 2)}${']' * (maxPlainYamlDepth + 2)}';
    expect(() => loadPlainYaml(deep), throwsFormatException);
    expect(loadPlainYaml('${'[' * 50}${']' * 50}'), isA<List>());
  });

  test('without merging, a merge key stays a plain key', () {
    expect(plainYaml(loadYaml('a: {<<: {b: 1}}'), merge: false), {
      'a': {
        '<<': {'b': 1},
      },
    });
  });
}
