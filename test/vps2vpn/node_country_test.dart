import 'package:fl_clash/vps2vpn/home.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a node name names its country, in Chinese or as a code', () {
    expect(vpsGuessCountry('新加坡 Hysteria2'), 'SG');
    expect(vpsGuessCountry('美国 REALITY'), 'US');
    expect(vpsGuessCountry('jp-reality'), 'JP');
    expect(vpsGuessCountry('HK 01'), 'HK');
  });

  test('no country when the name does not say one', () {
    expect(vpsGuessCountry('智能线路'), isNull);
    expect(vpsGuessCountry('Hysteria2'), isNull);
    // Letters inside a word are not a code.
    expect(vpsGuessCountry('sgp-usa'), isNull);
    // Home is not an exit.
    expect(vpsGuessCountry('CN relay'), isNull);
  });
}
