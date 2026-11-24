import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/vps2vpn/flags.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic>? _define(String name) => switch (name) {
  'sg-hy2' => {'type': 'hysteria2', 'server': '203.0.113.1'},
  'sg-tuic' => {'type': 'tuic', 'server': '203.0.113.1'},
  'us-hy2' => {'type': 'hysteria2', 'server': '198.51.100.2'},
  _ => {'type': 'Selector'},
};

Group _group(String name, List<String> members) => Group(
  type: GroupType.Selector,
  name: name,
  all: [for (final m in members) Proxy(name: m, type: 'Selector')],
);

void main() {
  test('under the smart line every server group it lists is watched', () async {
    final lines = await vpsCollectWatchedLines([
      _group(vpsSmartGroupName, ['SG', 'US']),
      _group('SG', ['sg-hy2', 'sg-tuic']),
      _group('US', ['us-hy2']),
      _group('Other', ['DIRECT']),
    ], define: (name) async => _define(name));

    expect(lines!.map((l) => l.name), ['sg-hy2', 'sg-tuic', 'us-hy2']);
    expect(lines.map((l) => l.kind), ['hy2', 'tuic', 'hy2']);
  });

  test('without the smart line the main selector is enough', () async {
    final lines = await vpsCollectWatchedLines([
      _group('Proxy', ['sg-hy2']),
      _group('Spare', ['us-hy2']),
    ], define: (name) async => _define(name));

    expect(lines!.map((l) => l.name), ['sg-hy2']);
  });

  test('every server group the main selector lists is watched', () async {
    final lines = await vpsCollectWatchedLines([
      _group('Proxy', ['SG', 'US']),
      _group('SG', ['sg-hy2']),
      _group('US', ['us-hy2']),
      _group('Spare', ['sg-tuic']),
    ], define: (name) async => _define(name));

    expect(lines!.map((l) => l.name), ['sg-hy2', 'us-hy2']);
  });

  test('a main selector with no lines falls through to the next', () async {
    final lines = await vpsCollectWatchedLines([
      _group('Proxy', ['Auto']),
      _group('Auto', ['us-hy2']),
    ], define: (name) async => _define(name));

    expect(lines!.map((l) => l.name), ['us-hy2']);
  });

  test('stops when the watch went away part way', () async {
    var asked = 0;
    final lines = await vpsCollectWatchedLines(
      [
        _group('Proxy', ['sg-hy2', 'us-hy2']),
      ],
      define: (name) async {
        asked++;
        return _define(name);
      },
      alive: () => false,
    );

    expect(lines, isNull);
    expect(asked, 1);
  });
}
