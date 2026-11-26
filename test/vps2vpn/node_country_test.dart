import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/vps2vpn/flags.dart';
import 'package:fl_clash/vps2vpn/home.dart';
import 'package:fl_clash/vps2vpn/servers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a node name names its country, in Chinese or as a code', () {
    expect(vpsGuessCountry('新加坡 Hysteria2'), 'SG');
    expect(vpsGuessCountry('美国 REALITY'), 'US');
    expect(vpsGuessCountry('jp-reality'), 'JP');
    expect(vpsGuessCountry('HK 01'), 'HK');
    expect(vpsGuessCountry('AI JP'), 'JP');
    expect(vpsGuessCountry('AI-SG-01'), 'SG');
    expect(vpsGuessCountry('IN Mumbai'), 'IN');
  });

  test('no country when the name does not say one', () {
    expect(vpsGuessCountry('智能线路'), isNull);
    expect(vpsGuessCountry('Hysteria2'), isNull);
    // Letters inside a word are not a code.
    expect(vpsGuessCountry('sgp-usa'), isNull);
    // Home is not an exit.
    expect(vpsGuessCountry('CN relay'), isNull);
    // Everyday words are not codes.
    expect(vpsGuessCountry('my line in Tokyo'), isNull);
    expect(vpsGuessCountry('id 3'), isNull);
  });

  test('a rate suffix and a flag emoji come off the name', () {
    expect(vpsNodeName('🇹🇼 台湾 · 5.0x'), (name: '台湾', rate: 5.0));
    expect(vpsNodeName('🇸🇬 新加坡(移动优化) · 2.0x'), (
      name: '新加坡(移动优化)',
      rate: 2.0,
    ));
    expect(vpsNodeName('香港 [0.5x]'), (name: '香港', rate: 0.5));
    expect(vpsNodeName('日本 x2'), (name: '日本', rate: 2.0));
    expect(vpsNodeName('美国 3倍'), (name: '美国', rate: 3.0));
    expect(vpsNodeName('韩国 倍率:1.5'), (name: '韩国', rate: 1.5));
    expect(vpsNodeName('🇹🇼 台湾 ×5'), (name: '台湾', rate: 5.0));
    expect(vpsNodeName('新加坡2'), (name: '新加坡2', rate: null));
    expect(vpsNodeName('Box2'), (name: 'Box2', rate: null));
    expect(vpsNodeName('🇯🇵'), (name: '🇯🇵', rate: null));
  });

  test('a node reads without its country code, its rate as ×', () {
    expect(vpsNodeShown('us 洛杉矶 · 5.0x'), (name: '洛杉矶', code: 'US', rate: 5.0));
    expect(vpsNodeShown('US-LA'), (name: 'LA', code: 'US', rate: null));
    expect(vpsNodeShown('jp东京 1x'), (name: '东京', code: 'JP', rate: 1.0));
    expect(vpsNodeShown('🇺🇸 洛杉矶'), (name: '洛杉矶', code: 'US', rate: null));
    expect(vpsNodeShown('sg'), (name: '', code: 'SG', rate: null));
    expect(vpsNodeShown('Hysteria2'), (
      name: 'Hysteria2',
      code: null,
      rate: null,
    ));
  });

  test("our panel's rate before the protocol comes off too", () {
    expect(vpsNodeName('美国 ×2 Hysteria2'), (name: '美国 Hysteria2', rate: 2.0));
    expect(vpsNodeName('Tokyo ×0.5 Reality'), (
      name: 'Tokyo Reality',
      rate: 0.5,
    ));
    expect(vpsNodeName('日本 TUIC'), (name: '日本 TUIC', rate: null));
  });

  test('a name that says its protocol', () {
    expect(vpsNameSaysProtocol('日本 Hysteria2', 'hysteria2'), isTrue);
    expect(vpsNameSaysProtocol('JP · Reality', 'vless'), isTrue);
    expect(vpsNameSaysProtocol('SG-HY2', 'hysteria2'), isTrue);
    expect(vpsNameSaysProtocol('新加坡 01', 'tuic'), isFalse);
    expect(vpsNameSaysProtocol('Russia', 'ss'), isFalse);
  });

  test('nodes of one region stay apart', () {
    final names = {
      for (final n in ['🇸🇬 新加坡', '🇸🇬 新加坡2', '🇸🇬 新加坡(移动优化) · 2.0x'])
        vpsNodeName(n).name,
    };
    expect(names, hasLength(3));
  });

  test("the smart line's server, past its hidden rate tiers", () {
    Group group(String name, String now) =>
        Group(type: GroupType.URLTest, name: name, now: now);
    final groups = [
      group(vpsSmartGroupName, vpsDearGroupName),
      group(vpsDearGroupName, 'TW · 5.0x'),
    ];
    expect(vpsServerNow(groups, groups.first), 'TW · 5.0x');
    expect(vpsServerNow(groups, group('Proxy', 'SG')), 'SG');
    expect(vpsServerNow(groups, null), isNull);
  });

  test('a flag emoji names the country first', () {
    expect(vpsGuessCountry('🇹🇼 台湾 · 5.0x'), 'TW');
    expect(vpsGuessCountry('🇭🇰 Hong Kong 01'), 'HK');
    expect(vpsGuessCountry('🇸🇬 新加坡(移动优化) · 2.0x'), 'SG');
  });
}
