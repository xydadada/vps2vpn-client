/// Lets a Core that died while connected come back on its own, a few times
/// in a window and never in a loop: a Core that keeps dying stays down.
class VpsCrashRestarts {
  VpsCrashRestarts({
    this.limit = 3,
    this.window = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int limit;
  final Duration window;
  final DateTime Function() _now;
  final _recent = <DateTime>[];

  /// Whether one more automatic restart fits; counts it when it does.
  bool take() {
    final now = _now();
    // A clock set back leaves restarts in the future; they cannot be aged,
    // so they no longer count.
    _recent.removeWhere(
      (at) => at.isAfter(now) || now.difference(at) >= window,
    );
    if (_recent.length >= limit) return false;
    _recent.add(now);
    return true;
  }
}
