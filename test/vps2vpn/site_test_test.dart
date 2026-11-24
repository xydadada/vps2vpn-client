import 'package:fl_clash/vps2vpn/site_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a bare host becomes an https site named after the host', () {
    expect(vpsSiteFrom(' www.github.com '), (
      name: 'github.com',
      url: 'https://www.github.com',
    ));
    expect(
      vpsSiteFrom('http://example.com/path')?.url,
      'http://example.com/path',
    );
  });

  test('what is not a web address is refused', () {
    for (final bad in ['', 'hello', 'ftp://example.com', 'two words.com']) {
      expect(vpsSiteFrom(bad), isNull, reason: bad);
    }
  });
}
