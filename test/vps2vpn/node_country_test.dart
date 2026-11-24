import 'package:fl_clash/vps2vpn/home.dart';
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
    expect(vpsNodeName('新加坡2'), (name: '新加坡2', rate: null));
    expect(vpsNodeName('Box2'), (name: 'Box2', rate: null));
    expect(vpsNodeName('🇯🇵'), (name: '🇯🇵', rate: null));
  });

  test('nodes of one region stay apart', () {
    final names = {
      for (final n in ['🇸🇬 新加坡', '🇸🇬 新加坡2', '🇸🇬 新加坡(移动优化) · 2.0x'])
        vpsNodeName(n).name,
    };
    expect(names, hasLength(3));
  });

  test('a flag emoji names the country first', () {
    expect(vpsGuessCountry('🇹🇼 台湾 · 5.0x'), 'TW');
    expect(vpsGuessCountry('🇭🇰 Hong Kong 01'), 'HK');
    expect(vpsGuessCountry('🇸🇬 新加坡(移动优化) · 2.0x'), 'SG');
  });
}
