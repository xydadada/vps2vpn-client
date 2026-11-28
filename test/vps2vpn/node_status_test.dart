import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/node_status.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _me({Object? features, Object? nodes}) => {
  'name': 'Ann',
  'enabled': true,
  'features': ?features,
  'nodes': ?nodes,
};

const _osaka = {
  'id': 'a1b2c3d4',
  'group': 'Osaka',
  'names': ['Osaka Hysteria2', 'Osaka Reality', 'Osaka Reality IPv6'],
  'state': 'maintenance',
  'note': '今晚 23:00–23:30 换机房',
  'until': 1795012200,
};

const _tokyo = {
  'id': 'main',
  'group': 'Tokyo',
  'names': ['Tokyo Reality'],
  'state': 'congested',
  'note': '',
  'until': 0,
};

void main() {
  test('no status unless the panel turns node_status on', () {
    expect(VpsMember.fromJson(_me()).nodes, isNull);
    expect(
      VpsMember.fromJson(
        _me(features: {'node_status': false}, nodes: [_osaka]),
      ).nodes,
      isNull,
    );
    expect(
      VpsMember.fromJson(_me(features: {'node_status': true})).nodes,
      isNull,
    );
    expect(
      VpsMember.fromJson(_me(features: 'yes', nodes: [_osaka])).nodes,
      isNull,
    );
  });

  test('the panel names its servers down or crowded', () {
    final nodes = VpsMember.fromJson(
      _me(
        features: {'traffic_rank': false, 'node_status': true},
        nodes: [
          _osaka,
          _tokyo,
          'junk',
          {'state': 'ok'},
        ],
      ),
    ).nodes!;
    expect(nodes, hasLength(2));
    final osaka = nodes.first;
    expect(osaka.state, VpsNodeState.maintenance);
    expect(osaka.group, 'Osaka');
    expect(osaka.note, '今晚 23:00–23:30 换机房');
    expect(osaka.until!.millisecondsSinceEpoch, 1795012200 * 1000);
    expect(nodes.last.state, VpsNodeState.congested);
    expect(nodes.last.until, isNull);
    final unknown = VpsNodeStatus.fromJson({
      'names': ['X'],
      'state': 'on fire',
      'note': 'n' * 300,
    })!;
    expect(unknown.state, VpsNodeState.ok);
    expect(unknown.note, hasLength(100));
  });

  test('a line is matched by its whole name, IPv6 suffix and all', () {
    final nodes = [VpsNodeStatus.fromJson(_osaka)!];
    final byName = vpsNodeStatusByName(nodes);
    expect(byName['Osaka Reality IPv6']?.state, VpsNodeState.maintenance);
    expect(byName['Osaka Reality'], isNotNull);
    expect(byName['Osaka Reality IPv4'], isNull);
    expect(byName['Osaka'], isNull);
  });

  test('down lines go to the Core last, crowded ones next to last', () {
    final container = ProviderContainer(
      overrides: [currentProfileProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(vpsNodeStatusProvider.notifier);
    expect(
      notifier.set([
        VpsNodeStatus.fromJson(_osaka)!,
        VpsNodeStatus.fromJson(_tokyo)!,
        VpsNodeStatus.fromJson({
          'names': ['Seoul Reality'],
          'state': 'ok',
        })!,
      ]),
      isTrue,
    );
    final avoid = vpsLinesToAvoid(container.read(vpsNodeStatusProvider));
    expect(avoid.down, [
      'Osaka Hysteria2',
      'Osaka Reality',
      'Osaka Reality IPv6',
    ]);
    expect(avoid.busy, ['Tokyo Reality']);
    expect(
      notifier.set([
        VpsNodeStatus.fromJson(_osaka)!,
        VpsNodeStatus.fromJson(_tokyo)!,
      ]),
      isFalse,
      reason: 'the same word twice rebuilds nothing',
    );
    expect(notifier.set(const []), isTrue);
  });

  test('the Core hears about the lines only when there are any', () {
    const quiet = CoreOptions(testUrl: 'test');
    expect(quiet.toJson().containsKey('vps2vpn-down-lines'), isFalse);
    const loud = CoreOptions(
      testUrl: 'test',
      downLines: ['Osaka Reality'],
      busyLines: ['Tokyo Reality'],
    );
    expect(loud.toJson()['vps2vpn-down-lines'], ['Osaka Reality']);
    expect(loud.toJson()['vps2vpn-busy-lines'], ['Tokyo Reality']);
  });

  test('maintenance state belongs to one profile and subscription URL', () {
    var profile = const Profile(
      id: 1,
      url: 'https://panel.example.com/s/TestToken0123456789',
      autoUpdateDuration: Duration(hours: 1),
    );
    final container = ProviderContainer(
      overrides: [currentProfileProvider.overrideWith((ref) => profile)],
    );
    addTearDown(container.dispose);
    final held = container.listen(vpsNodeStatusProvider, (_, _) {});
    addTearDown(held.close);
    final notifier = container.read(vpsNodeStatusProvider.notifier);
    final down = VpsNodeStatus.fromJson(_osaka)!;

    notifier.set([down]);
    profile = profile.copyWith(
      label: 'Renamed',
      lastUpdateDate: DateTime(2026),
    );
    container.invalidate(currentProfileProvider);
    expect(container.read(vpsNodeStatusProvider), [down]);

    profile = profile.copyWith(id: 2);
    container.invalidate(currentProfileProvider);
    expect(container.read(vpsNodeStatusProvider), isEmpty);
    expect(
      vpsLinesToAvoid(container.read(vpsNodeStatusProvider)).down,
      isEmpty,
    );

    notifier.set([down]);
    profile = profile.copyWith(url: 'https://provider.example/subscription');
    container.invalidate(currentProfileProvider);
    expect(container.read(vpsNodeStatusProvider), isEmpty);
  });
}
