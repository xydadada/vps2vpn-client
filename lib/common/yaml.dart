import 'package:fl_clash/common/yaml_writer.dart';
import 'package:yaml/yaml.dart';

class Yaml {
  static Yaml? _instance;

  Yaml._internal();

  factory Yaml() {
    _instance ??= Yaml._internal();
    return _instance!;
  }

  String encode(Object? value) {
    return writeYaml(value);
  }
}

final yaml = Yaml();

/// An alias is copied wherever it is used; a real subscription stays far below.
const maxPlainYamlValues = 1000000;
const maxPlainYamlDepth = 256;

/// Applies `<<` merge keys as mihomo does; package:yaml keeps them as keys.
Object? loadPlainYaml(String content) => plainYaml(loadYaml(content));

Object? plainYaml(Object? node, {bool merge = true}) =>
    _PlainYaml(merge).convert(node, 0);

class _PlainYaml {
  _PlainYaml(this.merge);

  final bool merge;
  var _values = 0;

  void _count(int depth) {
    if (++_values > maxPlainYamlValues) {
      throw const FormatException('The YAML expands to too many values');
    }
    if (depth > maxPlainYamlDepth) {
      throw const FormatException('The YAML nests too deeply');
    }
  }

  Object? convert(Object? node, int depth) {
    _count(depth);
    return switch (node) {
      YamlMap() when merge => _merged(node, depth),
      YamlMap() => {
        for (final MapEntry(:key, :value) in node.entries)
          key.toString(): convert(value, depth + 1),
      },
      YamlList() => [for (final item in node) convert(item, depth + 1)],
      _ => node,
    };
  }

  Map<String, Object?> _merged(YamlMap node, int depth) {
    final map = <String, Object?>{};
    final merged = <Object?>[];
    for (final MapEntry(:key, :value) in node.entries) {
      if (key == '<<') {
        merged.addAll(value is YamlList ? value : [value]);
      } else {
        map[key.toString()] = convert(value, depth + 1);
      }
    }
    for (final item in merged) {
      if (item is YamlMap) {
        _count(depth + 1);
        for (final MapEntry(:key, :value) in _merged(item, depth + 1).entries) {
          map.putIfAbsent(key, () => value);
        }
      }
    }
    return map;
  }
}
