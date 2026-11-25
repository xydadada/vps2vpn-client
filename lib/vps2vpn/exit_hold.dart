import 'dart:async';

import 'package:fl_clash/models/models.dart';

/// Keeps the last exit through a settling smart line's re-probes, at most [grace].
class VpsExitHold {
  VpsExitHold({
    required this.onExpire,
    this.grace = const Duration(seconds: 3),
  });

  final void Function() onExpire;
  final Duration grace;
  IpInfo? _held;
  Timer? _timer;

  IpInfo? steady(IpInfo? fresh, {required bool on}) {
    if (!on || fresh != null) {
      _timer?.cancel();
      _timer = null;
      return _held = on ? fresh : null;
    }
    if (_held == null) return null;
    _timer ??= Timer(grace, () {
      _timer = null;
      _held = null;
      onExpire();
    });
    return _held;
  }

  void dispose() => _timer?.cancel();
}
