// A subscription link as a QR code, for a phone to scan.

import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:flutter/widgets.dart';
import 'package:qr/qr.dart';

/// Dark modules on white with a quiet zone, whatever the theme: scanners
/// read dark-on-light.
class VpsQrCode extends StatelessWidget {
  const VpsQrCode(this.data, {super.key, this.size = 200});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final image = QrImage(
      QrCode(
        payload: QrPayload.fromString(data),
        errorCorrectLevel: QrErrorCorrectLevel.low,
      ),
    );
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _QrPainter(image)),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    const quiet = 4;
    final count = image.moduleCount + quiet * 2;
    final cell = size.width / count;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final dark = Paint()..color = const Color(0xFF000000);
    for (var row = 0; row < image.moduleCount; row++) {
      for (var col = 0; col < image.moduleCount; col++) {
        if (!image.isDark(row, col)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            (col + quiet) * cell,
            (row + quiet) * cell,
            cell + 0.5,
            cell + 0.5,
          ),
          dark,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}

/// "QR code" under a subscription: shown only when tapped, hidden again on
/// the next tap.
class VpsQrToggle extends StatefulWidget {
  const VpsQrToggle({super.key, required this.link});

  final String link;

  @override
  State<VpsQrToggle> createState() => _VpsQrToggleState();
}

class _VpsQrToggleState extends State<VpsQrToggle> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        VpsPressable(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              _open
                  ? tr(context, '收起二维码', 'Hide QR code')
                  : tr(context, '二维码（手机扫码导入）', 'QR code (scan with a phone)'),
              style: vpsText(
                p,
                size: 12.5,
                weight: FontWeight.w600,
                color: p.accent,
              ),
            ),
          ),
        ),
        if (_open) ...[
          const SizedBox(height: 10),
          Center(child: VpsQrCode(widget.link)),
          const SizedBox(height: 8),
          Text(
            tr(
              context,
              '二维码就是你的订阅链接，别截图发给别人。',
              'This code is your subscription link; do not share a picture of it.',
            ),
            style: vpsText(p, size: 12, color: p.warn),
          ),
        ],
      ],
    );
  }
}
