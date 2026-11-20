import 'package:fl_clash/common/compute.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

void main() {
  test('a computed group ignores a stale non-member saved selection', () {
    const groups = [
      Group(
        name: 'auto',
        type: GroupType.URLTest,
        all: [Proxy(name: 'leaf', type: 'ss')],
      ),
    ];
    final state = computeRealSelectedProxyState(
      'auto',
      groups: groups,
      selectedMap: const {'auto': 'auto'},
    );
    expect(state.proxyName, '');
    expect(state.group, isTrue);
    expect(state.testUrl, isNull);
    expect(
      computeProxyDelayState(
        proxyName: 'auto',
        testUrl: 'https://probe.test',
        groups: groups,
        selectedMap: const {'auto': 'unrelated'},
        delayMap: const {
          'https://probe.test': {'unrelated': 1},
        },
      ).delay,
      0,
    );
  });

  test('a self-selected group with no published members does not recurse', () {
    final state = computeRealSelectedProxyState(
      'auto',
      groups: const [Group(name: 'auto', type: GroupType.Selector)],
      selectedMap: const {'auto': 'auto'},
    );
    expect(state.proxyName, '');
    expect(state.group, isTrue);
  });

  test('a two-group cycle returns no probe target', () {
    final state = computeRealSelectedProxyState(
      'a',
      groups: const [
        Group(name: 'a', type: GroupType.URLTest),
        Group(name: 'b', type: GroupType.Fallback),
      ],
      selectedMap: const {'a': 'b', 'b': 'a'},
    );
    expect(state.proxyName, '');
    expect(state.group, isTrue);
    expect(state.testUrl, isNull);
  });

  test('a deep valid selection chain resolves without using the call stack', () {
    const count = 10000;
    final groups = [
      for (var i = 0; i < count; i++)
        Group(
          name: 'g$i',
          type: GroupType.Selector,
          testUrl: i == count - 1 ? 'https://last.test' : null,
          all: [
            Proxy(
              name: i == count - 1 ? 'leaf' : 'g${i + 1}',
              type: 'ss',
            ),
          ],
        ),
    ];
    final selections = {
      for (var i = 0; i < count; i++)
        'g$i': i == count - 1 ? 'leaf' : 'g${i + 1}',
    };
    final state = computeRealSelectedProxyState(
      'g0',
      groups: groups,
      selectedMap: selections,
    );
    expect(state.proxyName, 'leaf');
    expect(state.testUrl, 'https://last.test');
    expect(state.group, isTrue);
  });
}
