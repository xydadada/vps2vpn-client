import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/vps2vpn/home.dart';
import 'package:flutter_test/flutter_test.dart';

Group _selector(String name, List<String> members, {bool? hidden}) => Group(
  type: GroupType.Selector,
  name: name,
  hidden: hidden,
  all: [for (final m in members) Proxy(name: m, type: 'Direct')],
);

void main() {
  test('a group that starts with DIRECT or REJECT is not the main one', () {
    final groups = [
      _selector('Domestic', ['DIRECT', 'Proxy']),
      _selector('Ads', ['REJECT', 'DIRECT']),
      _selector('Proxy', ['SG · Reality', 'US · Reality']),
    ];
    expect(mainGroup(groups)?.name, 'Proxy');
  });

  test('hidden groups and other types are passed over', () {
    final groups = [
      _selector('Hidden', ['SG · Reality'], hidden: true),
      const Group(type: GroupType.URLTest, name: 'Auto'),
      _selector('Proxy', ['SG · Reality']),
    ];
    expect(mainGroup(groups)?.name, 'Proxy');
  });

  test('with only direct-first selectors the first of them stands', () {
    final groups = [
      _selector('Domestic', ['DIRECT']),
      _selector('Ads', ['REJECT']),
    ];
    expect(mainGroup(groups)?.name, 'Domestic');
    expect(mainGroup(const []), isNull);
  });
}
