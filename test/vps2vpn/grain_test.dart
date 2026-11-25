import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the grain is premultiplied and faint', () {
    final pixels = vpsGrainPixels(32);
    var lit = 0;
    for (var i = 0; i < pixels.length; i += 4) {
      final alpha = pixels[i + 3];
      expect(alpha, lessThanOrEqualTo(8));
      for (var c = 0; c < 3; c++) {
        expect(pixels[i + c], lessThanOrEqualTo(alpha));
      }
      if (pixels[i] > 0) lit++;
    }
    expect(lit, greaterThan(0));
  });
}
