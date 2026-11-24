import 'package:fl_clash/vps2vpn/clipboard_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool offered(String link) => vpsLooksLikeSubscription(link, link);

  test('any provider\'s subscription is offered, not only ours', () {
    expect(
      offered('https://panel.example.com/api/v1/client/subscribe?token=abc'),
      isTrue,
    );
    expect(offered('https://example.net/link/abc?clash=1'), isTrue);
    expect(offered('https://example.org/files/config.yaml'), isTrue);
    expect(offered('https://example.org/sub?target=clash&url=x'), isTrue);
  });

  test('an ordinary web address is no offer', () {
    expect(offered('https://example.com/news'), isFalse);
    expect(offered('https://example.com/'), isFalse);
    expect(offered('ftp://example.com/sub'), isFalse);
  });
}
