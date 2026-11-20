import 'dart:collection';
import 'dart:math' as math;

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

/// Applies `<<` merge keys as mihomo does; package:yaml keeps them as keys.
/// Editors that preserve literal keys can opt out without bypassing the graph
/// limits used before copying aliases.
Object? loadPlainYaml(String content, {bool mergeKeys = true}) {
  final node = loadYamlNode(content);
  _checkPlainYamlGraph(node);
  return _plainYaml(node.value, mergeKeys: mergeKeys);
}

/// Alias nodes share their targets in package:yaml, but the plain conversion
/// below intentionally makes independent copies. Check the DAG before copying,
/// including merge sources and map keys, so a small document cannot require an
/// exponential amount of work or memory.
void _checkPlainYamlGraph(YamlNode root) {
  const maxDepth = 256;
  const minExpansionBudget = 16 << 20;
  final seen = HashSet<YamlNode>.identity();
  final pending = <(YamlNode, int)>[(root, 0)];
  var originalWeight = 0;
  var hasAliases = false;
  while (pending.isNotEmpty) {
    final (node, depth) = pending.removeLast();
    if (depth > maxDepth) {
      throw const FormatException('YAML nesting is too deep');
    }
    if (!seen.add(node)) {
      hasAliases = true;
      continue;
    }
    originalWeight += _yamlNodeWeight(node);
    for (final child in _yamlNodeChildren(node)) {
      pending.add((child, depth + 1));
    }
  }
  // Ordinary large documents do not have an absolute node-count limit.
  if (!hasAliases) return;
  final budget = math.max(minExpansionBudget, originalWeight * 16);
  final weights = HashMap<YamlNode, int>.identity();
  final heights = HashMap<YamlNode, int>.identity();
  final active = HashSet<YamlNode>.identity();
  final stack = <(YamlNode, bool)>[(root, false)];
  while (stack.isNotEmpty) {
    final (node, complete) = stack.removeLast();
    if (weights.containsKey(node)) continue;
    if (!complete) {
      if (!active.add(node)) {
        throw const FormatException('Recursive YAML aliases are not supported');
      }
      stack.add((node, true));
      for (final child in _yamlNodeChildren(node)) {
        if (!weights.containsKey(child)) stack.add((child, false));
      }
      continue;
    }
    var weight = _yamlNodeWeight(node);
    var height = 0;
    for (final child in _yamlNodeChildren(node)) {
      height = math.max(height, heights[child]! + 1);
      // Saturate before addition; malicious DAGs can exceed int64's range.
      final childWeight = weights[child]!;
      weight = childWeight > budget - weight
          ? budget + 1
          : weight + childWeight;
    }
    if (height > maxDepth) {
      throw const FormatException('YAML nesting is too deep');
    }
    heights[node] = height;
    weights[node] = weight;
    active.remove(node);
  }
  if (weights[root]! > budget) {
    throw const FormatException(
      'YAML aliases expand beyond the supported size',
    );
  }
}

// A conservative estimate, not a claim about the VM's exact allocation size.
// Count UTF-16 code units without allocating another encoded copy of a scalar.
int _yamlNodeWeight(YamlNode node) =>
    32 + (node.value is String ? (node.value as String).length * 2 : 0);

Iterable<YamlNode> _yamlNodeChildren(YamlNode node) sync* {
  switch (node) {
    case YamlMap():
      for (final entry in node.nodes.entries) {
        yield entry.key as YamlNode;
        yield entry.value;
      }
    case YamlList():
      yield* node.nodes;
  }
}

Object? _plainYaml(Object? node, {bool mergeKeys = true}) => switch (node) {
  YamlMap() when !mergeKeys => {
    for (final entry in node.entries)
      entry.key.toString(): _plainYaml(entry.value, mergeKeys: false),
  },
  YamlMap() => _plainYamlMap(node),
  YamlList() => [
    for (final item in node) _plainYaml(item, mergeKeys: mergeKeys),
  ],
  _ => node,
};

Map<String, Object?> _plainYamlMap(YamlMap node) {
  final map = <String, Object?>{};
  final merged = <Object?>[];
  for (final MapEntry(:key, :value) in node.entries) {
    if (key == '<<') {
      merged.addAll(value is YamlList ? value : [value]);
    } else {
      map[key.toString()] = _plainYaml(value);
    }
  }
  for (final item in merged) {
    if (item is YamlMap) {
      for (final MapEntry(:key, :value) in _plainYamlMap(item).entries) {
        map.putIfAbsent(key, () => value);
      }
    }
  }
  return map;
}
