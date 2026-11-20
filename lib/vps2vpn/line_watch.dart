import 'dart:async';
import 'dart:convert';

class VpsLineReport {
  VpsLineReport(this.key, this.ok);

  final String key;
  final bool ok;
  DateTime? retryAt;
  int failures = 0;
}

class VpsLineHealth {
  VpsLineHealth({
    this.threshold = 3,
    this.refreshInterval = const Duration(hours: 6),
  }) : assert(threshold > 0),
       assert(refreshInterval > Duration.zero);

  final int threshold;
  final Duration refreshInterval;
  final _fails = <String, int>{};
  final _down = <String>{};
  final _pending = <String, VpsLineReport>{};
  final _refreshAt = <String, DateTime>{};

  bool? record(String key, bool ok) {
    bool? change;
    if (ok) {
      _fails.remove(key);
      _refreshAt.remove(key);
      if (_down.remove(key)) change = true;
    } else {
      final n = (_fails[key] ?? 0) + 1;
      _fails[key] = n < threshold ? n : threshold;
      if (n >= threshold && _down.add(key)) change = false;
    }
    if (change != null) _pending[key] = VpsLineReport(key, change);
    return change;
  }

  VpsLineReport? pending(String key, DateTime now) {
    var report = _pending[key];
    final refreshAt = _refreshAt[key];
    if (report == null &&
        _down.contains(key) &&
        refreshAt != null &&
        !now.isBefore(refreshAt)) {
      report = _pending[key] = VpsLineReport(key, false);
    }
    final retryAt = report?.retryAt;
    return retryAt == null || !now.isBefore(retryAt) ? report : null;
  }

  void complete(VpsLineReport report, bool delivered, DateTime now) {
    if (!identical(_pending[report.key], report)) return;
    if (delivered) {
      _pending.remove(report.key);
      if (!report.ok) {
        _refreshAt[report.key] = now.add(refreshInterval);
      }
      return;
    }
    const minutes = [4, 8, 16, 30];
    report.retryAt = now.add(Duration(minutes: minutes[report.failures]));
    if (report.failures < minutes.length - 1) report.failures++;
  }

  void retain(Set<String> keys) {
    _fails.removeWhere((key, _) => !keys.contains(key));
    _down.removeWhere((key) => !keys.contains(key));
    _pending.removeWhere((key, _) => !keys.contains(key));
    _refreshAt.removeWhere((key, _) => !keys.contains(key));
  }
}

class VpsWatchedLine {
  const VpsWatchedLine({
    required this.name,
    required this.kind,
    required this.host,
    required this.testUrl,
  });

  final String name;
  final String kind;
  final String host;
  final String testUrl;

  String get key => jsonEncode([kind, host]);
}

class VpsLineWatch {
  VpsLineWatch({
    required this.lines,
    required this.probe,
    required this.report,
    this.interval = const Duration(minutes: 4),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final Future<List<VpsWatchedLine>> Function() lines;
  final Future<bool> Function(VpsWatchedLine) probe;
  final Future<bool> Function(VpsWatchedLine, bool) report;
  final Duration interval;
  final DateTime Function() now;
  final _health = VpsLineHealth();
  Timer? _timer;
  Future<void>? _inFlight;
  bool _closed = false;

  void start() => _schedule();

  void _schedule() {
    _timer?.cancel();
    if (!_closed && _inFlight == null) {
      _timer = Timer(interval, () => unawaited(checkNow()));
    }
  }

  Future<void> checkNow() {
    if (_closed) return Future.value();
    if (_inFlight case final running?) return running;
    _timer?.cancel();
    return _inFlight = _check().whenComplete(() {
      _inFlight = null;
      _schedule();
    });
  }

  Future<void> _check() async {
    try {
      final current = await lines();
      if (_closed) return;
      _health.retain({for (final line in current) line.key});
      final endpoints = <String, List<VpsWatchedLine>>{};
      for (final line in current) {
        (endpoints[line.key] ??= []).add(line);
      }
      for (final alternatives in endpoints.values) {
        if (_closed) return;
        var ok = false;
        var unknown = false;
        for (final line in alternatives) {
          try {
            ok = await probe(line);
          } catch (_) {
            unknown = true;
          }
          if (_closed) return;
          if (ok) break;
        }
        // An unanswered probe is neither a failure nor a reason to skip the
        // other servers. A working alternative is still positive evidence.
        if (!ok && unknown) continue;
        final line = alternatives.first;
        _health.record(line.key, ok);
        final pending = _health.pending(line.key, now());
        if (pending == null) continue;
        var delivered = false;
        try {
          delivered = await report(line, pending.ok);
        } catch (_) {}
        if (_closed) return;
        _health.complete(pending, delivered, now());
      }
    } catch (_) {
      // An unanswered Core request is not evidence that a node is down.
    }
  }

  void dispose() {
    _closed = true;
    _timer?.cancel();
  }
}
