import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

typedef _Scrim = ({Color color, Animation<double> fade});

final _openScrims = ValueNotifier<List<_Scrim>>(const []);

// prism_ui keeps its alert spring private; this is the same curve.
final _alertSpring = SpringCurve(
  SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 275),
  ),
  seconds: 0.404,
);

void _changeScrims(List<_Scrim> Function(List<_Scrim>) change) {
  void apply() => _openScrims.value = change(_openScrims.value);
  if (SchedulerBinding.instance.schedulerPhase ==
      SchedulerPhase.persistentCallbacks) {
    SchedulerBinding.instance.addPostFrameCallback((_) => apply());
  } else {
    apply();
  }
}

/// Dims what lies outside the navigator, such as a window's title bar, along
/// with the open alerts' scrims; it never takes a pointer.
class AlertScrim extends StatelessWidget {
  const AlertScrim({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder(
        valueListenable: _openScrims,
        builder: (context, scrims, _) => Stack(
          fit: StackFit.expand,
          children: [
            for (final scrim in scrims)
              AnimatedBuilder(
                animation: scrim.fade,
                builder: (_, _) => ColoredBox(
                  color: scrim.color.withValues(
                    alpha: scrim.color.a * scrim.fade.value.clamp(0, 1),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Puts the scrim of the alert around [child] on every [AlertScrim] while
/// the alert is open.
class AlertScrimSource extends StatefulWidget {
  const AlertScrimSource({super.key, required this.child});

  final Widget child;

  @override
  State<AlertScrimSource> createState() => _AlertScrimSourceState();
}

class _AlertScrimSourceState extends State<AlertScrimSource> {
  _Scrim? _scrim;
  CurvedAnimation? _fade;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scrim != null) return;
    final route = ModalRoute.of(context);
    final color = route?.barrierColor;
    final animation = route?.animation;
    if (color == null || animation == null) return;
    final fade = _fade = CurvedAnimation(
      parent: animation,
      curve: _alertSpring,
      reverseCurve: _alertSpring.flipped,
    );
    final scrim = _scrim = (color: color, fade: fade);
    _changeScrims((scrims) => [...scrims, scrim]);
  }

  @override
  void dispose() {
    final scrim = _scrim;
    if (scrim != null) {
      _changeScrims((scrims) => [...scrims]..remove(scrim));
    }
    _fade?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
