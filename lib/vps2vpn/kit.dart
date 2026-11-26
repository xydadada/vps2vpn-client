// vps2vpn design kit: palette (dark "aurora", light "minimal"), cards,
// buttons, switches, segmented control, logo and line icons.
// Everything simple mode draws comes from here, so the look stays one system.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:fl_clash/ui/fonts.dart';
import 'package:prism_ui/prism_ui.dart'
    show
        AppRadius,
        AppShape,
        BuildContextExtension,
        InputDecoration,
        SpringCurve,
        TextField;
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const vpsCoral = Color(0xFFFF6F61);
const vpsCoralSoft = Color(0xFFFF8A70);
const vpsCoralDeep = Color(0xFFE63E5C);
const vpsViolet = Color(0xFF8B5CF6);

/// The English verb for pressing: "click" with a pointer, "tap" on a phone.
String vpsClick({bool start = false}) =>
    Platform.isAndroid ? (start ? 'Tap' : 'tap') : (start ? 'Click' : 'click');

/// The logo keeps the brand colours whatever theme colour is picked.
const vpsBrandGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [vpsCoralSoft, vpsCoralDeep, vpsViolet],
  stops: [0, 0.65, 1],
);

/// The theme colour simple mode draws its accent from, per brightness.
class VpsAccentScope extends InheritedWidget {
  const VpsAccentScope({
    super.key,
    required this.light,
    required this.dark,
    required super.child,
  });

  final Color light;
  final Color dark;

  static Color? seedOf(BuildContext context, {required bool dark}) {
    final scope = context.dependOnInheritedWidgetOfExactType<VpsAccentScope>();
    return dark ? scope?.dark : scope?.light;
  }

  @override
  bool updateShouldNotify(VpsAccentScope old) =>
      old.light != light || old.dark != dark;
}

HSLColor vpsAtLuminance(HSLColor c, double min, double max) {
  var lo = 0.0;
  var hi = 1.0;
  final lum = c.toColor().computeLuminance();
  if (lum >= min && lum <= max) return c;
  final target = lum < min ? min : max;
  for (var i = 0; i < 24; i++) {
    final mid = (lo + hi) / 2;
    if (c.withLightness(mid).toColor().computeLuminance() < target) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return c.withLightness(lum < min ? hi : lo);
}

Color vpsReadable(Color c, Color on, double ratio) {
  final l = on.computeLuminance();
  final up = l < 0.18;
  final edge = up ? ratio * (l + 0.05) - 0.05 : (l + 0.05) / ratio - 0.05;
  final now = c.computeLuminance();
  if (up ? now >= edge : now <= edge) return c;
  return vpsAtLuminance(
    HSLColor.fromColor(c),
    up ? edge : 0,
    up ? 1 : edge,
  ).toColor();
}

double _lightness(Color c) {
  final y = c.computeLuminance();
  return y > 0.008856 ? 116 * math.pow(y, 1 / 3) - 16 : 903.3 * y;
}

double _luminanceAt(double lightness) => lightness > 8
    ? math.pow((lightness + 16) / 116, 3).toDouble()
    : lightness / 903.3;

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
    required this.selected,
    required this.lineHover,
    required this.toggleOff,
    required this.popover,
    this.seed = vpsCoral,
    this.gradient = const [vpsCoralSoft, vpsCoralDeep, vpsViolet],
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
  final Color selected;
  final Color lineHover;
  final Color toggleOff;
  final Color popover;

  final Color seed;
  final List<Color> gradient;

  // Neutral greys in clear steps (page < sidebar < card < raised), the way
  // macOS and iOS group content: colour is kept for state and the one main
  // action, so green, amber and red read at a glance.
  static const _dark = VpsPalette._(
    dark: true,
    bg: Color(0xFF0D0D10),
    side: Color(0xFF111114),
    card: Color(0xFF1A1A1E),
    cardHi: Color(0xFF222227),
    line: Color(0x17FFFFFF),
    text: Color(0xFFF5F5F7),
    soft: Color(0xFF9A9AA1),
    muted: Color(0xFF636369),
    accent: Color(0xFFFF7A5C),
    accentInk: Color(0xFFFFFFFF),
    accentWash: Color(0x1FFF7A5C),
    good: Color(0xFF32D74B),
    warn: Color(0xFFFFB340),
    bad: Color(0xFFFF5A52),
    glowA: Color(0x00000000),
    glowB: Color(0x00000000),
    track: Color(0xFF131316),
    thumb: Color(0xFF2C2C31),
    selected: Color(0x12FFFFFF),
    lineHover: Color(0x29FFFFFF),
    toggleOff: Color(0xFF2E2E33),
    popover: Color(0xF2222227),
  );

  // Apple's grouped-content greys: cards float on a cool grey page.
  static const _light = VpsPalette._(
    dark: false,
    bg: Color(0xFFF2F2F7),
    side: Color(0xFFF9F9FB),
    card: Color(0xFFFFFFFF),
    cardHi: Color(0xFFFFFFFF),
    line: Color(0xFFE3E3E8),
    text: Color(0xFF1D1D1F),
    soft: Color(0xFF6E6E73),
    muted: Color(0xFFAEAEB2),
    accent: Color(0xFFEF5B3C),
    accentInk: Color(0xFFFFFFFF),
    accentWash: Color(0xFFFDEEE9),
    good: Color(0xFF1F9A3E),
    warn: Color(0xFFC26A00),
    bad: Color(0xFFD70015),
    glowA: Color(0x00000000),
    glowB: Color(0x00000000),
    track: Color(0xFFEBEBF0),
    thumb: Color(0xFFFFFFFF),
    selected: Color(0xFFEEF0F3),
    lineHover: Color(0xFFD5D5DA),
    toggleOff: Color(0xFFDCDCE1),
    popover: Color(0xF7FFFFFF),
  );

  static final _tinted = <(int, bool), VpsPalette>{};
  static final _inks = <(int, int, bool), Color>{};

  /// Grey and status text toned to read at AA on a card; dots and fills keep [c].
  Color ink(Color c, {bool large = false}) {
    if (c != soft &&
        c != muted &&
        c != accent &&
        c != good &&
        c != warn &&
        c != bad) {
      return c;
    }
    return _inks.putIfAbsent((
      c.toARGB32(),
      card.toARGB32(),
      large,
    ), () => _ink(c, large ? 3 : 4.5));
  }

  /// Grey text sits a clear step (8 L*) off muted text, so the two levels hold.
  Color _ink(Color c, double ratio) {
    final toned = vpsReadable(c, card, ratio);
    if (c != soft) return toned;
    final step = _lightness(vpsReadable(muted, card, ratio)) + (dark ? 8 : -8);
    final y = _luminanceAt(step);
    final now = toned.computeLuminance();
    if (dark ? now >= y : now <= y) return toned;
    return vpsAtLuminance(
      HSLColor.fromColor(toned),
      dark ? y : 0,
      dark ? 1 : y,
    ).toColor();
  }

  static VpsPalette of(BuildContext context) {
    final base = context.colorScheme.brightness == Brightness.dark
        ? _dark
        : _light;
    final seed = VpsAccentScope.seedOf(context, dark: base.dark);
    if (seed == null || seed.toARGB32() == vpsCoral.toARGB32()) return base;
    return _tinted.putIfAbsent((
      seed.toARGB32(),
      base.dark,
    ), () => base.tinted(seed));
  }

  /// The accent sits where white text on it reads and, in dark, it still
  /// stands off the page.
  VpsPalette tinted(Color seed) {
    final hsl = HSLColor.fromColor(seed);
    final accent = vpsAtLuminance(
      hsl,
      dark ? 0.2 : 0.1,
      dark ? 0.35 : 0.27,
    ).toColor();
    final a = HSLColor.fromColor(accent);
    return VpsPalette._(
      dark: dark,
      bg: bg,
      side: side,
      card: card,
      cardHi: cardHi,
      line: line,
      text: text,
      soft: soft,
      muted: muted,
      accent: accent,
      accentInk: accentInk,
      accentWash: dark
          ? accent.withValues(alpha: 0.12)
          : Color.alphaBlend(accent.withValues(alpha: 0.1), card),
      good: good,
      warn: warn,
      bad: bad,
      glowA: glowA,
      glowB: glowB,
      track: track,
      thumb: thumb,
      selected: selected,
      lineHover: lineHover,
      toggleOff: toggleOff,
      popover: popover,
      seed: seed,
      gradient: [
        _turn(
          a,
          8,
        ).withLightness((a.lightness + 0.08).clamp(0, 0.82)).toColor(),
        _turn(
          a,
          -6,
        ).withLightness((a.lightness - 0.04).clamp(0.2, 1)).toColor(),
        _turn(a, 35).toColor(),
      ],
    );
  }

  static HSLColor _turn(HSLColor c, double degrees) =>
      c.withHue((c.hue + degrees) % 360);

  LinearGradient get accentGradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: gradient,
    stops: const [0, 0.65, 1],
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

/// Inter draws Latin letters and figures; Chinese falls through to Noto
/// Sans SC (bundled, common characters), then the system's own.
const vpsFont = 'Inter';
const vpsFontFallback = [
  'NotoSansSC',
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'PingFang SC',
];

TextStyle vpsText(
  VpsPalette p, {
  double size = 14,
  FontWeight weight = FontWeight.w400,
  Color? color,
  double? height,
  double? spacing,
  bool tabular = true,
}) => TextStyle(
  fontFamily: vpsFont,
  fontFamilyFallback: vpsFontFallback,
  fontSize: size,
  fontWeight: weight,
  color: p.ink(
    color ?? p.text,
    large: size >= 24 || size >= 18.66 && weight.value >= 700,
  ),
  height: height,
  letterSpacing: spacing,
  fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
);

/// One line box of [size] for Latin and CJK alike, so mixed labels in a row
/// share a baseline.
StrutStyle vpsStrut(double size, {double height = 1.3}) =>
    StrutStyle(fontSize: size, height: height, forceStrutHeight: true);

/// The rounded surface every block sits on: glass in dark, paper in light.
class VpsCard extends StatefulWidget {
  const VpsCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.radius = VpsRadius.large,
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
  State<VpsCard> createState() => _VpsCardState();
}

class _VpsCardState extends State<VpsCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    // Under the pointer the edge catches a little more light, like a lifted
    // pane; the change is slight on purpose.
    final edge = widget.highlight
        ? p.accent.withValues(alpha: _hover ? 0.7 : 0.5)
        : _hover
        ? p.lineHover
        : p.line;
    final box = AnimatedContainer(
      duration: VpsMotion.fast,
      curve: VpsMotion.settle,
      padding: widget.padding,
      decoration: ShapeDecoration(
        color: widget.highlight ? p.cardHi : p.card,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(widget.radius),
          side: BorderSide(color: edge),
        ),
        shadows: p.raise,
      ),
      child: widget.child,
    );
    final hovered = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          box,
          if (p.dark && !widget.highlight)
            // Light from above, inside the edge, fading a pixel down.
            for (final (row, alpha) in const [(1.0, 0x14), (2.0, 0x08)])
              Positioned(
                top: row,
                left: widget.radius,
                right: widget.radius,
                height: 1,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0x00FFFFFF),
                          Color(alpha << 24 | 0xFFFFFF),
                          Color(alpha << 24 | 0xFFFFFF),
                          const Color(0x00FFFFFF),
                        ],
                        stops: const [0, 0.2, 0.8, 1],
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
    if (widget.onTap == null) {
      return widget.selected == null
          ? hovered
          : Semantics(selected: widget.selected, child: hovered);
    }
    return VpsPressable(
      onTap: widget.onTap,
      selected: widget.selected,
      child: hovered,
    );
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
          SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false):
              ActivateIntent(),
          SingleActivator(
            LogicalKeyboardKey.numpadEnter,
            includeRepeats: false,
          ): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
              ActivateIntent(),
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
            child: VpsSpringScale(
              scale: enabled && _down ? 0.97 : (enabled && _hover ? 1.006 : 1),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Corner radii, four steps; every corner is a superellipse.
abstract final class VpsRadius {
  static const double small = 8;
  static const double medium = 12;
  static const double large = 20;
  static const double pill = 999;
}

/// Durations, three steps, and the curve state changes settle on.
abstract final class VpsMotion {
  static const fast = Duration(milliseconds: 150);
  static const medium = Duration(milliseconds: 250);
  static const slow = Duration(milliseconds: 450);

  /// A critically damped spring: quick out of the gate, no wobble.
  static final Curve settle = SpringCurve(
    SpringDescription.withDampingRatio(mass: 1, stiffness: 180, ratio: 1),
    seconds: 0.5,
  );

  /// Leaving: gathers speed, so what goes does not linger.
  static const Curve leave = Curves.easeInCubic;
}

/// The spring every press and state change rides on: a little under-damped,
/// so it settles with one soft overshoot, the way iOS controls do.
final vpsSpring = SpringDescription.withDampingRatio(
  mass: 1,
  stiffness: 420,
  ratio: 0.62,
);

/// Scales [child] towards [scale] on a spring. A new target mid-flight keeps
/// the current speed instead of restarting, so quick presses never stutter.
class VpsSpringScale extends StatefulWidget {
  const VpsSpringScale({super.key, required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  State<VpsSpringScale> createState() => _VpsSpringScaleState();
}

class _VpsSpringScaleState extends State<VpsSpringScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
    value: widget.scale,
  );

  @override
  void didUpdateWidget(VpsSpringScale old) {
    super.didUpdateWidget(old);
    if (old.scale != widget.scale) {
      _c.animateWith(
        SpringSimulation(vpsSpring, _c.value, widget.scale, _c.velocity),
      );
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, child) => Transform.scale(scale: _c.value, child: child),
    child: widget.child,
  );
}

/// Fades [child] in while it rises a few pixels, [index] beats after the
/// page appears: a page's blocks arrive in order instead of all at once.
/// Plays once, when the page is built.
class VpsEnter extends StatelessWidget {
  const VpsEnter({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final delay = 0.09 * index.clamp(0, 8);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 520 + 50 * index.clamp(0, 8)),
      curve: Interval(delay.clamp(0.0, 0.5), 1, curve: VpsMotion.settle),
      builder: (_, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, 14 * (1 - v)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Breathes [child] between faint and full while [active]: "still working
/// on it", without a spinner.
class VpsBreathe extends StatefulWidget {
  const VpsBreathe({super.key, required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<VpsBreathe> createState() => _VpsBreatheState();
}

class _VpsBreatheState extends State<VpsBreathe>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _c,
    curve: Curves.easeInOutSine,
  );
  late final Animation<double> _opacity = Tween(
    begin: 0.38,
    end: 1.0,
  ).animate(_curve);

  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
    _sync();
  }

  @override
  void didUpdateWidget(VpsBreathe old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.active && !_still) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else if (_c.isAnimating) {
      _c.stop();
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active || _still) return widget.child;
    return FadeTransition(opacity: _opacity, child: widget.child);
  }
}

/// A breathing placeholder the size of what is still on its way.
class VpsSkeleton extends StatelessWidget {
  const VpsSkeleton({super.key, required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: VpsBreathe(
      active: true,
      child: Container(
        width: width,
        height: height,
        decoration: ShapeDecoration(
          color: VpsPalette.of(context).track,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(VpsRadius.pill),
          ),
        ),
      ),
    ),
  );
}

String? vpsFlagEmoji(String code) {
  final c = code.trim().toUpperCase();
  if (!RegExp(r'^[A-Z]{2}$').hasMatch(c)) return null;
  return String.fromCharCodes([
    for (final unit in c.codeUnits) 0x1F1E6 + unit - 0x41,
  ]);
}

/// Drawn by the bundled Twemoji font: Windows has no flag emoji of its own.
class VpsFlag extends StatelessWidget {
  const VpsFlag(this.code, {super.key, this.size = 22});

  final String code;
  final double size;

  @override
  Widget build(BuildContext context) {
    final flag = vpsFlagEmoji(code);
    final p = VpsPalette.of(context);
    if (flag == null) {
      return Text(
        code.toUpperCase(),
        style: vpsText(p, size: size * 0.55, weight: FontWeight.w600),
      );
    }
    final span = _flagSpan[code.toUpperCase()] ?? (38, 1238);
    return Semantics(
      label: code.toUpperCase(),
      child: ExcludeSemantics(
        child: CustomPaint(
          foregroundPainter: span.$1 < 0
              ? null
              : _FlagEdge(
                  span: span,
                  size: size,
                  pixel: 1 / MediaQuery.devicePixelRatioOf(context),
                  color: p.dark
                      ? const Color(0x24FFFFFF)
                      : const Color(0x1A000000),
                ),
          child: Text(
            flag,
            textScaler: TextScaler.noScaling,
            style: TextStyle(
              fontFamily: FontFamily.twEmoji.value,
              fontSize: size,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// [text] that rolls up into place when it changes, like a flip counter:
/// live numbers move instead of blinking.
class VpsRollingText extends StatelessWidget {
  const VpsRollingText(
    this.text, {
    super.key,
    required this.style,
    this.maxLines = 1,
  });

  final String text;
  final TextStyle style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: VpsMotion.medium,
      switchInCurve: VpsMotion.settle,
      switchOutCurve: VpsMotion.leave,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, a) {
        final incoming = child.key == ValueKey(text);
        return ClipRect(
          child: SlideTransition(
            position: Tween(
              begin: Offset(0, incoming ? 0.5 : -0.5),
              end: Offset.zero,
            ).animate(a),
            child: FadeTransition(opacity: a, child: child),
          ),
        );
      },
      child: Text(
        text,
        key: ValueKey(text),
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }
}

/// The colour of the light behind the window: the connection's state, set
/// by the overview. Null is the quiet brand light of "not connected".
final vpsAmbient = ValueNotifier<Color?>(null);

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
            borderRadius: BorderRadius.circular(VpsRadius.medium),
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
              style: vpsText(p, size: 13.5, weight: FontWeight.w600, color: fg),
            ),
          ],
        ),
      ),
    );
  }
}

/// A text field as tall as a [VpsButton] beside it, in its type size, its
/// edge neutral until it has focus.
class VpsField extends StatefulWidget {
  const VpsField({
    super.key,
    required this.controller,
    this.focusNode,
    this.hint,
    this.error,
    this.errorMaxLines = 2,
    this.keyboardType,
    this.textInputAction,
    this.minLines,
    this.maxLines = 1,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? hint;
  final String? error;
  final int errorMaxLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final int? minLines;
  final int? maxLines;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<VpsField> createState() => _VpsFieldState();
}

class _VpsFieldState extends State<VpsField> {
  FocusNode? _own;

  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode());

  void _changed() => setState(() {});

  @override
  void initState() {
    super.initState();
    _focus.addListener(_changed);
  }

  @override
  void didUpdateWidget(VpsField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.focusNode ?? _own;
    if (old != _focus) {
      old?.removeListener(_changed);
      _focus.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_changed);
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final error = widget.error;
    final focused = _focus.hasFocus;
    final edge = error != null
        ? p.bad
        : focused
        ? p.accent
        : p.line;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: VpsMotion.fast,
          curve: VpsMotion.settle,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: ShapeDecoration(
            color: p.card,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(VpsRadius.medium),
              side: BorderSide(color: edge),
            ),
            shadows: [
              BoxShadow(
                color: edge.withValues(alpha: focused ? 0.16 : 0),
                spreadRadius: 3,
              ),
            ],
          ),
          child: TextField(
            controller: widget.controller,
            focusNode: _focus,
            keyboardType: widget.keyboardType,
            textInputAction: widget.textInputAction,
            autocorrect: false,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
            onChanged: widget.onChanged,
            onSubmitted: widget.onSubmitted,
            cursorColor: p.accent,
            style: vpsText(p, size: 13.5),
            decoration: InputDecoration.collapsed(
              hintText: widget.hint ?? '',
              hintStyle: vpsText(p, size: 13.5, color: p.muted),
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
            child: Text(
              error,
              maxLines: widget.errorMaxLines,
              overflow: TextOverflow.ellipsis,
              style: vpsText(p, size: 12, color: p.bad),
            ),
          ),
      ],
    );
  }
}

/// Scrolls [child]; an edge with more beyond it fades out, so a line is never
/// cut in half there.
class VpsFadingScroll extends StatefulWidget {
  const VpsFadingScroll({super.key, required this.child});

  final Widget child;

  @override
  State<VpsFadingScroll> createState() => _VpsFadingScrollState();
}

class _VpsFadingScrollState extends State<VpsFadingScroll> {
  var _top = false;
  var _bottom = false;

  bool _sync(ScrollMetrics m) {
    final top = m.extentBefore > 0.5;
    final bottom = m.extentAfter > 0.5;
    if (top != _top || bottom != _bottom) {
      setState(() {
        _top = top;
        _bottom = bottom;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    const edge = 28.0;
    const solid = Color(0xFF000000);
    const clear = Color(0x00000000);
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (r) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_top ? clear : solid, solid, solid, _bottom ? clear : solid],
        stops: [0, edge / r.height, 1 - edge / r.height, 1],
      ).createShader(r),
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (n) => n.depth == 0 && _sync(n.metrics),
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) => n.depth == 0 && _sync(n.metrics),
          child: SingleChildScrollView(child: widget.child),
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
        duration: VpsMotion.medium,
        curve: VpsMotion.settle,
        width: 40,
        height: 24,
        padding: const EdgeInsets.all(2.5),
        decoration: ShapeDecoration(
          color: value ? p.accent : p.toggleOff,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(VpsRadius.pill),
          ),
        ),
        child: AnimatedAlign(
          duration: VpsMotion.medium,
          curve: VpsMotion.settle,
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
              borderRadius: BorderRadius.circular(VpsRadius.medium),
              side: BorderSide(color: p.line),
            ),
          ),
          child: Stack(
            children: [
              AnimatedPositioned(
                duration: VpsMotion.medium,
                curve: VpsMotion.settle,
                left: w * index,
                top: 0,
                bottom: 0,
                width: w,
                child: Container(
                  decoration: ShapeDecoration(
                    color: p.thumb,
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(VpsRadius.small),
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
                              p,
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

class _BeatDot extends StatefulWidget {
  const _BeatDot({required this.color, required this.beat});

  final Color color;
  final Object? beat;

  @override
  State<_BeatDot> createState() => _BeatDotState();
}

class _BeatDotState extends State<_BeatDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  late final Animation<double> _scale = _c.drive(
    TweenSequence([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1,
          end: 1.7,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.7,
          end: 1,
        ).chain(CurveTween(curve: VpsMotion.settle)),
        weight: 65,
      ),
    ]),
  );

  @override
  void didUpdateWidget(_BeatDot old) {
    super.didUpdateWidget(old);
    if (widget.beat != null &&
        old.beat != widget.beat &&
        !MediaQuery.disableAnimationsOf(context)) {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: _scale,
    child: Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    ),
  );
}

class VpsChip extends StatelessWidget {
  const VpsChip({
    super.key,
    required this.label,
    this.unit,
    this.color,
    this.tinted = false,
    this.beat,
  });

  final String label;

  /// Set a size smaller and quieter after [label].
  final String? unit;
  final Color? color;

  /// The dot hops each time this changes: a sign of life.
  final Object? beat;

  /// A capsule washed in [color] with text in it: for the one state that
  /// matters on a card, where a dot is too quiet.
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final c = color ?? p.accent;
    if (tinted) {
      return AnimatedContainer(
        duration: VpsMotion.slow,
        curve: VpsMotion.settle,
        padding: const EdgeInsets.fromLTRB(10, 5, 12, 5),
        decoration: ShapeDecoration(
          color: c.withValues(alpha: p.dark ? 0.16 : 0.12),
          shape: AppShape.full,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _BeatDot(color: c, beat: beat),
            const SizedBox(width: 7),
            Text(
              label,
              style: vpsText(p, size: 12.5, weight: FontWeight.w600, color: c),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 4, 11, 4),
      decoration: ShapeDecoration(
        color: p.track,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(VpsRadius.pill),
          side: BorderSide(color: p.line),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text.rich(
            TextSpan(
              text: label,
              children: [
                if (unit case final unit?)
                  TextSpan(
                    text: ' $unit',
                    style: vpsText(p, size: 10.5, color: p.soft),
                  ),
              ],
            ),
            style: vpsText(p, size: 12, weight: FontWeight.w500, color: p.text),
          ),
        ],
      ),
    );
  }
}

/// Twemoji flags span x 38–1238, y −83–783 of a 1024 em (ascent 950, descent
/// 250) with corners of 4/36 of their width; these few are narrower, and
/// Nepal's pennant (−1) gets no edge.
const _flagSpan = {
  'BE': (138, 1138),
  'CH': (204, 1071),
  'VA': (204, 1071),
  'NP': (-1, -1),
};

class _FlagEdge extends CustomPainter {
  _FlagEdge({
    required this.span,
    required this.size,
    required this.pixel,
    required this.color,
  });

  final (int, int) span;
  final double size;
  final double pixel;
  final Color color;

  @override
  void paint(Canvas canvas, Size box) {
    final em = size / 1024;
    final baseline = size * 950 / 1200;
    final rect = Rect.fromLTRB(
      span.$1 * em,
      baseline - 783 * em,
      span.$2 * em,
      baseline + 83 * em,
    ).deflate(pixel / 2);
    canvas.drawRSuperellipse(
      RSuperellipse.fromRectAndRadius(rect, Radius.circular(1200 * em / 9)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = pixel
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_FlagEdge old) =>
      old.span != span ||
      old.size != size ||
      old.pixel != pixel ||
      old.color != color;
}

/// The vps2vpn mark: a rounded tile with a "V" path rising to a point,
/// read as "your server" (the dot) feeding a secure tunnel (the V).
class VpsLogo extends StatelessWidget {
  const VpsLogo({super.key, this.size = 36});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        gradient: vpsBrandGradient,
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
  tick,
  close,
  power,
  gauge,
  wifi,
  network,
  tray,
  qr,
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
      case VpsIcon.tick:
        canvas.drawPath(
          poly([
            [5, 12.5],
            [10, 17.5],
            [19, 7],
          ]),
          p..strokeWidth = 2.6 * u,
        );
      case VpsIcon.close:
        canvas
          ..drawLine(o(6.5, 6.5), o(17.5, 17.5), p)
          ..drawLine(o(17.5, 6.5), o(6.5, 17.5), p);
      case VpsIcon.power:
        canvas
          ..drawArc(
            Rect.fromCircle(center: o(12, 13), radius: 7.5 * u),
            -math.pi / 2 + 0.65,
            math.pi * 2 - 1.3,
            false,
            p,
          )
          ..drawLine(o(12, 3.5), o(12, 11), p);
      case VpsIcon.gauge:
        canvas
          ..drawArc(
            Rect.fromCircle(center: o(12, 14), radius: 8.5 * u),
            math.pi * 0.8,
            math.pi * 1.4,
            false,
            p,
          )
          ..drawLine(o(12, 14), o(16.5, 8.5), p)
          ..drawCircle(o(12, 14), 1.2 * u, Paint()..color = color);
      case VpsIcon.wifi:
        for (final r in const [4.5, 9.0, 13.5]) {
          canvas.drawArc(
            Rect.fromCircle(center: o(12, 19.5), radius: r * u),
            -math.pi * 0.75,
            math.pi * 0.5,
            false,
            p,
          );
        }
        canvas.drawCircle(o(12, 19.5), 1.2 * u, Paint()..color = color);
      case VpsIcon.network:
        canvas
          ..drawRSuperellipse(rr(9, 3.5, 15, 8.5, 1.5), p)
          ..drawRSuperellipse(rr(3.5, 15.5, 9.5, 20.5, 1.5), p)
          ..drawRSuperellipse(rr(14.5, 15.5, 20.5, 20.5, 1.5), p)
          ..drawLine(o(12, 8.5), o(12, 12), p)
          ..drawLine(o(6.5, 12), o(17.5, 12), p)
          ..drawLine(o(6.5, 12), o(6.5, 15.5), p)
          ..drawLine(o(17.5, 12), o(17.5, 15.5), p);
      case VpsIcon.tray:
        canvas
          ..drawRSuperellipse(rr(3.5, 4.5, 20.5, 19.5, 2.5), p)
          ..drawLine(o(3.5, 14.5), o(20.5, 14.5), p)
          ..drawLine(o(15.5, 17), o(17.5, 17), p);
      case VpsIcon.qr:
        final fill = Paint()..color = color;
        canvas
          ..drawRSuperellipse(rr(4, 4, 10.5, 10.5, 1.5), p)
          ..drawRSuperellipse(rr(13.5, 4, 20, 10.5, 1.5), p)
          ..drawRSuperellipse(rr(4, 13.5, 10.5, 20, 1.5), p)
          ..drawRect(Rect.fromLTRB(13.5 * u, 13.5 * u, 16 * u, 16 * u), fill)
          ..drawRect(Rect.fromLTRB(17.5 * u, 17.5 * u, 20 * u, 20 * u), fill)
          ..drawRect(Rect.fromLTRB(17.5 * u, 13.5 * u, 20 * u, 16 * u), fill)
          ..drawRect(Rect.fromLTRB(13.5 * u, 17.5 * u, 16 * u, 20 * u), fill);
    }
  }

  @override
  bool shouldRepaint(_IconPainter old) =>
      old.icon != icon || old.color != color;
}

/// The background: deep night with two soft glows (dark) or warm paper (light).
class VpsBackdrop extends StatelessWidget {
  const VpsBackdrop({super.key, required Widget this.child}) : lift = 0;

  /// The strip [lift] tall above a [VpsBackdrop], lined up with it.
  const VpsBackdrop.above({super.key, required this.lift}) : child = null;

  final Widget? child;
  final double lift;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    // Two faint pools of the state's colour, one behind the content and one
    // under the glass sidebar, cross-fading slowly when the state changes:
    // the window itself says "connected" or "something is wrong".
    return ColoredBox(
      color: p.bg,
      child: ValueListenableBuilder<Color?>(
        valueListenable: vpsAmbient,
        builder: (context, tone, child) => TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: tone ?? p.accent),
          duration: const Duration(milliseconds: 900),
          curve: VpsMotion.settle,
          builder: (context, c, child) {
            final color = c ?? p.accent;
            return Stack(
              children: [
                Positioned(
                  top: -360 + lift,
                  right: -260,
                  child: _Glow(
                    color: color.withValues(alpha: p.dark ? 0.13 : 0.10),
                    size: 820,
                  ),
                ),
                if (lift == 0)
                  Positioned(
                    bottom: -380,
                    left: -260,
                    child: _Glow(
                      color: color.withValues(alpha: p.dark ? 0.09 : 0.07),
                      size: 720,
                    ),
                  ),
                Positioned.fill(child: _Grain(dy: lift)),
                if (child != null) Positioned.fill(child: child),
              ],
            );
          },
          child: child,
        ),
        child: child,
      ),
    );
  }
}

/// Premultiplied: a colour above its alpha is read as light added, which
/// turned the grain into full-strength static.
@visibleForTesting
Uint8List vpsGrainPixels(int side) {
  final random = math.Random(7);
  final pixels = Uint8List(side * side * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    final alpha = random.nextInt(9);
    final light = random.nextBool() ? alpha : 0;
    pixels
      ..[i] = light
      ..[i + 1] = light
      ..[i + 2] = light
      ..[i + 3] = alpha;
  }
  return pixels;
}

/// A faint film grain over the glows, so their gradients do not band.
class _Grain extends StatefulWidget {
  const _Grain({this.dy = 0});

  final double dy;

  @override
  State<_Grain> createState() => _GrainState();
}

class _GrainState extends State<_Grain> {
  static Future<ui.Image>? _tile;

  static Future<ui.Image> _make() {
    const side = 128;
    final pixels = vpsGrainPixels(side);
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      side,
      side,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }

  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    (_tile ??= _make()).then((image) {
      if (mounted) setState(() => _image = image);
    });
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(painter: _GrainPainter(image, widget.dy)),
      ),
    );
  }
}

class _GrainPainter extends CustomPainter {
  _GrainPainter(this.image, this.dy);

  final ui.Image image;
  final double dy;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ImageShader(
          image,
          TileMode.repeated,
          TileMode.repeated,
          Matrix4.translationValues(0, dy, 0).storage,
        ),
    );
  }

  @override
  bool shouldRepaint(_GrainPainter old) => old.image != image || old.dy != dy;
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
                p,
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
    this.info,
    this.trailing,
    this.onTap,
  });

  final VpsIcon icon;
  final String title;
  final String? subtitle;

  /// The whole story behind [subtitle], in a "?" beside the title.
  final String? info;
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
                borderRadius: BorderRadius.circular(VpsRadius.small),
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
                if (info == null)
                  Text(
                    title,
                    style: vpsText(p, size: 14.5, weight: FontWeight.w500),
                  )
                else
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: vpsText(
                            p,
                            size: 14.5,
                            weight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      VpsInfoTip(info!),
                    ],
                  ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: vpsText(p, size: 12.5, color: p.soft),
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
      hoverDelay: VpsMotion.fast,
      tooltipBuilder: (context, animation) => FadeTransition(
        opacity: animation,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
            decoration: ShapeDecoration(
              color: p.popover,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(VpsRadius.medium),
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
                      style: vpsText(p, size: 13, weight: FontWeight.w600),
                    ),
                  ),
                Text(
                  message,
                  style: vpsText(p, size: 12.5, color: p.soft, height: 1.5),
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
              p,
              size: 10.5,
              weight: FontWeight.w600,
              color: p.soft,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
