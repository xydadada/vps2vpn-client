// vps2vpn design kit: palette (dark "aurora", light "minimal"), cards,
// buttons, switches, segmented control, logo and line icons.
// Everything simple mode draws comes from here, so the look stays one system.

import 'dart:math' as math;

import 'package:prism_ui/prism_ui.dart' show AppRadius, BuildContextExtension;
import 'package:prism_ui/typography.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const vpsCoral = Color(0xFFFF6F61);
const vpsCoralSoft = Color(0xFFFF8A70);
const vpsCoralDeep = Color(0xFFE63E5C);
const vpsViolet = Color(0xFF8B5CF6);

class VpsPalette {
  const VpsPalette._({
    required this.dark,
    required this.bg,
    required this.side,
    required this.card,
    required this.cardHi,
    required this.line,
    required this.text,
    required this.soft,
    required this.muted,
    required this.accent,
    required this.accentInk,
    required this.accentWash,
    required this.good,
    required this.warn,
    required this.bad,
    required this.glowA,
    required this.glowB,
    required this.track,
    required this.thumb,
  });

  final bool dark;
  final Color bg;
  final Color side;
  final Color card;
  final Color cardHi;
  final Color line;
  final Color text;
  final Color soft;
  final Color muted;
  final Color accent;
  final Color accentInk;
  final Color accentWash;
  final Color good;
  final Color warn;
  final Color bad;
  final Color glowA;
  final Color glowB;

  /// Inset surface: segmented tracks, off switches, icon tiles.
  final Color track;

  /// Raised surface on a track: the chosen segment.
  final Color thumb;

  // Graphite, not navy: quieter, reads as a tool rather than a toy.
  static const _dark = VpsPalette._(
    dark: true,
    bg: Color(0xFF0B0C0F),
    side: Color(0xFF0E0F13),
    card: Color(0xFF14161B),
    cardHi: Color(0xFF181B21),
    line: Color(0x14FFFFFF),
    text: Color(0xFFECEDEF),
    soft: Color(0xFF8B9099),
    muted: Color(0xFF575C66),
    accent: Color(0xFFFF7A5C),
    accentInk: Color(0xFFFFFFFF),
    accentWash: Color(0x1FFF7A5C),
    good: Color(0xFF5BD69A),
    warn: Color(0xFFF0B44C),
    bad: Color(0xFFF0716B),
    glowA: Color(0x1FFF6F61),
    glowB: Color(0x148B5CF6),
    track: Color(0xFF0F1115),
    thumb: Color(0xFF262931),
  );

  // Neutral paper, no tint: the accent alone carries the brand.
  static const _light = VpsPalette._(
    dark: false,
    bg: Color(0xFFF5F6F8),
    side: Color(0xFFFBFBFC),
    card: Color(0xFFFFFFFF),
    cardHi: Color(0xFFFFFFFF),
    line: Color(0xFFE6E8EC),
    text: Color(0xFF111318),
    soft: Color(0xFF6B7280),
    muted: Color(0xFFA3A8B1),
    accent: Color(0xFFEF5B3C),
    accentInk: Color(0xFFFFFFFF),
    accentWash: Color(0xFFFDEEE9),
    good: Color(0xFF15965E),
    warn: Color(0xFFB7791F),
    bad: Color(0xFFDC4A3F),
    glowA: Color(0x00000000),
    glowB: Color(0x00000000),
    track: Color(0xFFEFF1F4),
    thumb: Color(0xFFFFFFFF),
  );

  static VpsPalette of(BuildContext context) =>
      context.colorScheme.brightness == Brightness.dark ? _dark : _light;

  /// Brand gradient: logo and the connect button only.
  LinearGradient get accentGradient => const LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [vpsCoralSoft, vpsCoralDeep, vpsViolet],
    stops: [0, 0.65, 1],
  );

  List<BoxShadow> get raise => dark
      ? const []
      : const [
          BoxShadow(
            color: Color(0x0A101828),
            blurRadius: 2,
            offset: Offset(0, 1),
          ),
          BoxShadow(
            color: Color(0x0D101828),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ];
}

bool vpsZh(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'zh';

/// Picks the Chinese or English text by the app's language.
String tr(BuildContext context, String zh, String en) =>
    vpsZh(context) ? zh : en;

TextStyle vpsText(
  BuildContext context, {
  double size = 14,
  FontWeight weight = FontWeight.w400,
  Color? color,
  double? height,
  double? spacing,
  bool tabular = false,
}) {
  final inherited = DefaultTextStyle.of(context).style;
  return AppTextStyle.custom(
    context,
    size: size,
    leading: size * (height ?? inherited.height ?? kTextHeightNone),
    weight: weight,
  ).copyWith(
    color: color ?? VpsPalette.of(context).text,
    letterSpacing: spacing ?? inherited.letterSpacing,
    fontFeatures: tabular
        ? const [FontFeature.tabularFigures()]
        : inherited.fontFeatures,
  );
}

/// The rounded surface every block sits on: glass in dark, paper in light.
class VpsCard extends StatelessWidget {
  const VpsCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.radius = 16,
    this.onTap,
    this.highlight = false,
    this.selected,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final bool highlight;
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final box = Container(
      padding: padding,
      decoration: ShapeDecoration(
        color: highlight ? p.cardHi : p.card,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(
            color: highlight ? p.accent.withValues(alpha: 0.5) : p.line,
          ),
        ),
        shadows: p.raise,
      ),
      child: child,
    );
    if (onTap == null) {
      return selected == null ? box : Semantics(selected: selected, child: box);
    }
    return VpsPressable(onTap: onTap, selected: selected, child: box);
  }
}

/// Hover lift + press shrink + click cursor for anything tappable.
class VpsPressable extends StatefulWidget {
  const VpsPressable({
    super.key,
    required this.onTap,
    this.semanticLabel,
    this.selected,
    this.toggled,
    required this.child,
  });

  final VoidCallback? onTap;
  final String? semanticLabel;
  final bool? selected;
  final bool? toggled;
  final Widget child;

  @override
  State<VpsPressable> createState() => _VpsPressableState();
}

class _VpsPressableState extends State<VpsPressable> {
  final _focusNode = FocusNode();
  bool _hover = false;
  bool _down = false;
  bool _focused = false;
  bool _showFocus = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_syncPrimaryFocus);
  }

  @override
  void didUpdateWidget(covariant VpsPressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onTap == null && (_down || _hover)) {
      _down = false;
      _hover = false;
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_syncPrimaryFocus);
    _focusNode.dispose();
    super.dispose();
  }

  void _syncPrimaryFocus() {
    final primary = _focusNode.hasPrimaryFocus;
    if (_focused != primary) {
      setState(() => _focused = primary);
    }
  }

  void _activate() {
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Semantics(
      // A switch merges into its row (MergeSemantics), so the row reads as
      // "Take over, on" rather than two separate nodes.
      container: widget.toggled == null,
      label: widget.semanticLabel,
      button: widget.toggled == null,
      enabled: enabled,
      selected: widget.selected,
      toggled: widget.toggled,
      focusable: enabled,
      focused: _focused,
      onTap: enabled ? _activate : null,
      child: FocusableActionDetector(
        enabled: enabled,
        focusNode: _focusNode,
        includeFocusSemantics: false,
        mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onFocusChange: (_) =>
            setState(() => _focused = _focusNode.hasPrimaryFocus),
        onShowFocusHighlight: (value) => setState(() => _showFocus = value),
        onShowHoverHighlight: (value) => setState(() => _hover = value),
        shortcuts: const {
          SingleActivator(
            LogicalKeyboardKey.enter,
            includeRepeats: false,
          ): ActivateIntent(),
          SingleActivator(
            LogicalKeyboardKey.numpadEnter,
            includeRepeats: false,
          ): ActivateIntent(),
          SingleActivator(
            LogicalKeyboardKey.space,
            includeRepeats: false,
          ): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activate();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapCancel: enabled ? () => setState(() => _down = false) : null,
          onTapUp: enabled ? (_) => setState(() => _down = false) : null,
          onTap: enabled ? _activate : null,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: ShapeDecoration(
              shape: RoundedSuperellipseBorder(
                borderRadius: AppRadius.sm,
                side: _showFocus && _focused && enabled
                    ? BorderSide(color: VpsPalette.of(context).accent, width: 2)
                    : BorderSide.none,
              ),
            ),
            child: AnimatedScale(
              scale: enabled && _down ? 0.985 : (enabled && _hover ? 1.004 : 1),
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// A pill button: filled (accent) or quiet (outline).
class VpsButton extends StatelessWidget {
  const VpsButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.filled = false,
  });

  final String label;
  final VoidCallback? onTap;
  final VpsIcon? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final disabled = onTap == null;
    final bg = filled
        ? (disabled ? p.accent.withValues(alpha: 0.45) : p.accent)
        : p.card;
    final fg = disabled
        ? (filled ? p.accentInk.withValues(alpha: 0.85) : p.muted)
        : (filled ? p.accentInk : p.text);
    return VpsPressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: ShapeDecoration(
          color: bg,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(10),
            side: filled ? BorderSide.none : BorderSide(color: p.line),
          ),
          shadows: filled ? const [] : p.raise,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              VpsIconView(icon!, size: 16, color: fg),
              const SizedBox(width: 7),
            ],
            Text(
              label,
              style: vpsText(
                context,
                size: 13.5,
                weight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A smooth custom switch.
class VpsSwitch extends StatelessWidget {
  const VpsSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    return VpsPressable(
      onTap: () => onChanged(!value),
      toggled: value,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: 40,
        height: 24,
        padding: const EdgeInsets.all(2.5),
        decoration: ShapeDecoration(
          color: value
              ? p.accent
              : (p.dark ? const Color(0xFF2A2D35) : const Color(0xFFDCDFE4)),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(99),
          ),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 19,
            height: 19,
            decoration: const BoxDecoration(
              color: Color(0xFFFFFFFF),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Two or three choices in one pill, the chosen one slides.
class VpsSegmented<T> extends StatelessWidget {
  const VpsSegmented({
    super.key,
    required this.items,
    required this.value,
    required this.labelOf,
    required this.onChanged,
  });

  final List<T> items;
  final T value;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final index = math.max(0, items.indexOf(value));
    return LayoutBuilder(
      builder: (context, c) {
        final w = (c.maxWidth - 8) / items.length;
        return Container(
          height: 40,
          padding: const EdgeInsets.all(4),
          decoration: ShapeDecoration(
            color: p.track,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: p.line),
            ),
          ),
          child: Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                left: w * index,
                top: 0,
                bottom: 0,
                width: w,
                child: Container(
                  decoration: ShapeDecoration(
                    color: p.thumb,
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(7),
                      side: p.dark
                          ? const BorderSide(color: Color(0x0FFFFFFF))
                          : BorderSide.none,
                    ),
                    shadows: p.dark
                        ? const [
                            BoxShadow(
                              color: Color(0x66000000),
                              blurRadius: 6,
                              offset: Offset(0, 2),
                            ),
                          ]
                        : const [
                            BoxShadow(
                              color: Color(0x14101828),
                              blurRadius: 3,
                              offset: Offset(0, 1),
                            ),
                            BoxShadow(
                              color: Color(0x0A101828),
                              blurRadius: 8,
                              offset: Offset(0, 2),
                            ),
                          ],
                  ),
                ),
              ),
              Row(
                children: [
                  for (final item in items)
                    Expanded(
                      child: VpsPressable(
                        onTap: () => onChanged(item),
                        selected: item == value,
                        child: Center(
                          child: Text(
                            labelOf(item),
                            style: vpsText(
                              context,
                              size: 13.5,
                              weight: item == value
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: item == value ? p.text : p.soft,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class VpsChip extends StatelessWidget {
  const VpsChip({super.key, required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final c = color ?? p.accent;
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 4, 11, 4),
      decoration: ShapeDecoration(
        color: p.track,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(99),
          side: BorderSide(color: p.line),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: vpsText(
              context,
              size: 12,
              weight: FontWeight.w500,
              color: p.text,
            ),
          ),
        ],
      ),
    );
  }
}

/// The vps2vpn mark: a rounded tile with a "V" path rising to a point,
/// read as "your server" (the dot) feeding a secure tunnel (the V).
class VpsLogo extends StatelessWidget {
  const VpsLogo({super.key, this.size = 36});

  final double size;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        gradient: p.accentGradient,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(size * 0.28),
        ),
        shadows: [
          BoxShadow(
            color: vpsCoral.withValues(alpha: 0.22),
            blurRadius: size * 0.35,
            offset: Offset(0, size * 0.1),
          ),
        ],
      ),
      child: CustomPaint(painter: _LogoMark()),
    );
  }
}

class _LogoMark extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width;
    final stroke = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(w * 0.27, w * 0.34)
      ..lineTo(w * 0.5, w * 0.74)
      ..lineTo(w * 0.73, w * 0.34);
    canvas.drawPath(path, stroke);
    canvas.drawCircle(
      Offset(w * 0.5, w * 0.3),
      w * 0.075,
      Paint()..color = const Color(0xFFFFFFFF),
    );
  }

  @override
  bool shouldRepaint(_LogoMark oldDelegate) => false;
}

/// Our own line icons, drawn so nothing looks borrowed.
enum VpsIcon {
  home,
  servers,
  check,
  me,
  bolt,
  globe,
  shield,
  refresh,
  paste,
  file,
  gear,
  info,
  sun,
  arrowUp,
  arrowDown,
  sparkle,
  plus,
  chevron,
}

class VpsIconView extends StatelessWidget {
  const VpsIconView(this.icon, {super.key, this.size = 22, this.color});

  final VpsIcon icon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? VpsPalette.of(context).text;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _IconPainter(icon, c)),
    );
  }
}

class _IconPainter extends CustomPainter {
  _IconPainter(this.icon, this.color);

  final VpsIcon icon;
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final u = s.width / 24;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * u
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Offset o(double x, double y) => Offset(x * u, y * u);
    RSuperellipse rr(double l, double t, double r, double b, double rad) =>
        RSuperellipse.fromLTRBR(
          l * u,
          t * u,
          r * u,
          b * u,
          Radius.circular(rad * u),
        );
    Path poly(List<List<double>> pts, {bool close = false}) {
      final path = Path()..moveTo(pts[0][0] * u, pts[0][1] * u);
      for (final pt in pts.skip(1)) {
        path.lineTo(pt[0] * u, pt[1] * u);
      }
      if (close) path.close();
      return path;
    }

    switch (icon) {
      case VpsIcon.home:
        canvas.drawPath(
          poly([
            [3.5, 11],
            [12, 4],
            [20.5, 11],
          ]),
          p,
        );
        canvas.drawPath(
          poly([
            [6, 9.5],
            [6, 20],
            [18, 20],
            [18, 9.5],
          ]),
          p,
        );
        canvas.drawLine(o(10, 20), o(10, 15), p);
        canvas.drawLine(o(14, 20), o(14, 15), p);
        canvas.drawLine(o(10, 15), o(14, 15), p);
      case VpsIcon.servers:
        canvas.drawRSuperellipse(rr(4, 4, 20, 10.5, 2.5), p);
        canvas.drawRSuperellipse(rr(4, 13.5, 20, 20, 2.5), p);
        canvas.drawCircle(o(7.5, 7.25), 0.9 * u, p..style = PaintingStyle.fill);
        canvas.drawCircle(o(7.5, 16.75), 0.9 * u, p);
        p.style = PaintingStyle.stroke;
        canvas.drawLine(o(12, 7.25), o(16.5, 7.25), p);
        canvas.drawLine(o(12, 16.75), o(16.5, 16.75), p);
      case VpsIcon.check:
        canvas.drawPath(
          poly([
            [12, 3],
            [19.5, 6],
            [19.5, 12],
            [12, 21],
            [4.5, 12],
            [4.5, 6],
          ], close: true),
          p,
        );
        canvas.drawPath(
          poly([
            [8.5, 12],
            [11, 14.5],
            [15.5, 9.5],
          ]),
          p,
        );
      case VpsIcon.me:
        canvas.drawCircle(o(12, 8.5), 3.8 * u, p);
        canvas.drawArc(
          Rect.fromLTRB(4.5 * u, 14 * u, 19.5 * u, 28 * u),
          math.pi * 1.08,
          math.pi * 0.84,
          false,
          p,
        );
      case VpsIcon.bolt:
        canvas.drawPath(
          poly([
            [13, 3],
            [5.5, 13.5],
            [11.5, 13.5],
            [10.5, 21],
            [18.5, 10.5],
            [12.5, 10.5],
          ], close: true),
          p,
        );
      case VpsIcon.globe:
        canvas.drawCircle(o(12, 12), 8.5 * u, p);
        canvas.drawOval(Rect.fromLTRB(8 * u, 3.5 * u, 16 * u, 20.5 * u), p);
        canvas.drawLine(o(3.5, 12), o(20.5, 12), p);
      case VpsIcon.shield:
        canvas.drawPath(
          poly([
            [12, 3],
            [19.5, 6],
            [19.5, 12],
            [12, 21],
            [4.5, 12],
            [4.5, 6],
          ], close: true),
          p,
        );
      case VpsIcon.refresh:
        canvas.drawArc(
          Rect.fromCircle(center: o(12, 12), radius: 7.5 * u),
          -math.pi * 0.35,
          math.pi * 1.6,
          false,
          p,
        );
        canvas.drawPath(
          poly([
            [17.5, 3.5],
            [18.2, 7.6],
            [14, 8],
          ]),
          p,
        );
      case VpsIcon.paste:
        canvas.drawRSuperellipse(rr(5, 5, 19, 21, 2.5), p);
        canvas.drawRSuperellipse(rr(9, 3, 15, 7, 1.5), p);
        canvas.drawLine(o(9, 12), o(15, 12), p);
        canvas.drawLine(o(9, 16), o(13, 16), p);
      case VpsIcon.file:
        canvas.drawPath(
          poly([
            [6, 3],
            [14, 3],
            [19, 8],
            [19, 21],
            [6, 21],
          ], close: true),
          p,
        );
        canvas.drawPath(
          poly([
            [14, 3],
            [14, 8],
            [19, 8],
          ]),
          p,
        );
      case VpsIcon.gear:
        canvas.drawCircle(o(12, 12), 3 * u, p);
        for (var i = 0; i < 8; i++) {
          final a = i * math.pi / 4;
          canvas.drawLine(
            o(12 + 6 * math.cos(a), 12 + 6 * math.sin(a)),
            o(12 + 8.5 * math.cos(a), 12 + 8.5 * math.sin(a)),
            p,
          );
        }
        canvas.drawCircle(o(12, 12), 6 * u, p);
      case VpsIcon.info:
        canvas.drawCircle(o(12, 12), 8.5 * u, p);
        canvas.drawLine(o(12, 11), o(12, 16.5), p);
        canvas.drawCircle(o(12, 7.8), 0.6 * u, p);
      case VpsIcon.sun:
        canvas.drawCircle(o(12, 12), 4 * u, p);
        for (var i = 0; i < 8; i++) {
          final a = i * math.pi / 4;
          canvas.drawLine(
            o(12 + 6.5 * math.cos(a), 12 + 6.5 * math.sin(a)),
            o(12 + 8.5 * math.cos(a), 12 + 8.5 * math.sin(a)),
            p,
          );
        }
      case VpsIcon.arrowUp:
        canvas.drawLine(o(12, 19), o(12, 5), p);
        canvas.drawPath(
          poly([
            [6.5, 10.5],
            [12, 5],
            [17.5, 10.5],
          ]),
          p,
        );
      case VpsIcon.arrowDown:
        canvas.drawLine(o(12, 5), o(12, 19), p);
        canvas.drawPath(
          poly([
            [6.5, 13.5],
            [12, 19],
            [17.5, 13.5],
          ]),
          p,
        );
      case VpsIcon.sparkle:
        canvas.drawPath(
          poly([
            [12, 3],
            [13.8, 10.2],
            [21, 12],
            [13.8, 13.8],
            [12, 21],
            [10.2, 13.8],
            [3, 12],
            [10.2, 10.2],
          ], close: true),
          p,
        );
      case VpsIcon.plus:
        canvas.drawLine(o(12, 5), o(12, 19), p);
        canvas.drawLine(o(5, 12), o(19, 12), p);
      case VpsIcon.chevron:
        canvas.drawPath(
          poly([
            [9, 5],
            [16, 12],
            [9, 19],
          ]),
          p,
        );
    }
  }

  @override
  bool shouldRepaint(_IconPainter old) =>
      old.icon != icon || old.color != color;
}

/// The background: deep night with two soft glows (dark) or warm paper (light).
class VpsBackdrop extends StatelessWidget {
  const VpsBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    return ColoredBox(
      color: p.bg,
      child: Stack(
        children: [
          if (p.dark) ...[
            Positioned(
              top: -320,
              right: -220,
              child: _Glow(color: p.glowA, size: 760),
            ),
            Positioned(
              bottom: -360,
              left: 120,
              child: _Glow(color: p.glowB, size: 700),
            ),
          ],
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      ),
    );
  }
}

class VpsSectionTitle extends StatelessWidget {
  const VpsSectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 10, top: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: vpsText(
                context,
                size: 12.5,
                weight: FontWeight.w500,
                color: p.soft,
                spacing: 0.4,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A settings-style row inside a card.
class VpsRow extends StatelessWidget {
  const VpsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final VpsIcon icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: ShapeDecoration(
              color: p.track,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(9),
                side: BorderSide(color: p.line),
              ),
            ),
            alignment: Alignment.center,
            child: VpsIconView(icon, size: 17, color: p.soft),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: vpsText(context, size: 14.5, weight: FontWeight.w500),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: vpsText(context, size: 12.5, color: p.soft),
                    ),
                  ),
              ],
            ),
          ),
          trailing ??
              (onTap != null
                  ? VpsIconView(VpsIcon.chevron, size: 18, color: p.muted)
                  : const SizedBox()),
        ],
      ),
    );
    if (onTap == null) {
      return trailing is VpsSwitch ? MergeSemantics(child: row) : row;
    }
    return VpsPressable(onTap: onTap!, child: row);
  }
}

/// A small circled "?" that explains a term on hover (tap on touch screens).
class VpsInfoTip extends StatelessWidget {
  const VpsInfoTip(this.message, {super.key, this.title});

  final String? title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    return RawTooltip(
      semanticsTooltip: message,
      triggerMode: TooltipTriggerMode.tap,
      hoverDelay: const Duration(milliseconds: 120),
      tooltipBuilder: (context, animation) => FadeTransition(
        opacity: animation,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
            decoration: ShapeDecoration(
              color: p.dark ? const Color(0xF2232536) : const Color(0xF7FFFFFF),
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: p.line),
              ),
              shadows: [
                BoxShadow(
                  color: const Color(
                    0xFF000000,
                  ).withValues(alpha: p.dark ? 0.4 : 0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      title!,
                      style: vpsText(
                        context,
                        size: 13,
                        weight: FontWeight.w700,
                      ),
                    ),
                  ),
                Text(
                  message,
                  style: vpsText(
                    context,
                    size: 12.5,
                    color: p.soft,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      positionDelegate: (position) => positionDependentBox(
        size: position.overlaySize,
        childSize: position.tooltipSize,
        target: position.target,
        verticalOffset: 16,
        preferBelow: true,
      ),
      ignorePointer: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.help,
        child: Container(
          width: 17,
          height: 17,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: p.muted, width: 1.2),
          ),
          child: Text(
            '?',
            style: vpsText(
              context,
              size: 10.5,
              weight: FontWeight.w700,
              color: p.soft,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
