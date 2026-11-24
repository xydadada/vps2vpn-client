// vps2vpn: what each subscription update brought, kept across restarts, so
// the subscription card can say when it last updated, what changed, and how
// long its address has been out of reach.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/vps2vpn/kit.dart' show tr;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Days of failed updates, and at least this many tries, before the card
/// says the address may be gone for good.
const vpsDeadAfter = Duration(days: 3);
const vpsDeadAfterTries = 3;

/// How long nodes an update added keep their "new" tag.
const vpsNewNodeFor = Duration(hours: 24);

class VpsProfileHealth {
  const VpsProfileHealth({
    this.at,
    this.ok = true,
    this.error,
    this.unreachable = false,
    this.failingSince,
    this.failures = 0,
    this.added = const [],
    this.removed = 0,
    this.changed = false,
    this.changedAt,
  });

  final DateTime? at;
  final bool ok;
  final String? error;

  /// The last failure never reached the subscription's server.
  final bool unreachable;
  final DateTime? failingSince;
  final int failures;

  /// Node names the last update that changed anything added.
  final List<String> added;
  final int removed;

  final bool changed;
  final DateTime? changedAt;

  bool deadAt(DateTime now) =>
      !ok &&
      failures >= vpsDeadAfterTries &&
      failingSince != null &&
      now.difference(failingSince!) >= vpsDeadAfter;

  bool isNew(String node, DateTime now) =>
      changedAt != null &&
      now.difference(changedAt!) < vpsNewNodeFor &&
      added.contains(node);

  Map<String, Object?> toJson() => {
    'at': at?.millisecondsSinceEpoch,
    'ok': ok,
    'error': error,
    'unreachable': unreachable,
    'failingSince': failingSince?.millisecondsSinceEpoch,
    'failures': failures,
    'added': added,
    'removed': removed,
    'changed': changed,
    'changedAt': changedAt?.millisecondsSinceEpoch,
  };

  static DateTime? _time(Object? v) =>
      v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;

  factory VpsProfileHealth.fromJson(Map<String, Object?> json) =>
      VpsProfileHealth(
        at: _time(json['at']),
        ok: json['ok'] != false,
        error: json['error'] is String ? json['error']! as String : null,
        unreachable: json['unreachable'] == true,
        failingSince: _time(json['failingSince']),
        failures: json['failures'] is int ? json['failures']! as int : 0,
        added: [
          for (final n in json['added'] is List ? json['added']! as List : [])
            if (n is String) n,
        ],
        removed: json['removed'] is int ? json['removed']! as int : 0,
        changed: json['changed'] == true,
        changedAt: _time(json['changedAt']),
      );
}

/// A profile file's node names (null when it lists none we can read) and a
/// digest of its bytes.
typedef VpsProfileSnapshot = ({List<String>? nodes, String? digest});

const _maxSnapshotBytes = 16 << 20;

Future<VpsProfileSnapshot> Function(int profileId) vpsReadSnapshot =
    (id) async {
      if (Platform.environment.containsKey('FLUTTER_TEST')) {
        return (nodes: null, digest: null);
      }
      try {
        final file = File(await appPath.getProfilePath(id.toString()));
        if (!await file.exists() || await file.length() > _maxSnapshotBytes) {
          return (nodes: null, digest: null);
        }
        final bytes = await file.readAsBytes();
        return await Isolate.run(() => vpsSnapshotOf(bytes));
      } catch (_) {
        return (nodes: null, digest: null);
      }
    };

VpsProfileSnapshot vpsSnapshotOf(List<int> bytes) {
  final digest = sha1.convert(bytes).toString();
  try {
    final doc = loadPlainYaml(utf8.decode(bytes, allowMalformed: true));
    final proxies = doc is Map ? doc['proxies'] : null;
    if (proxies is! List) return (nodes: null, digest: digest);
    return (
      nodes: [
        for (final p in proxies)
          if (p is Map && p['name'] is String) p['name'] as String,
      ],
      digest: digest,
    );
  } catch (_) {
    return (nodes: null, digest: digest);
  }
}

bool vpsUnreachable(Object error) {
  final t = error.toString().toLowerCase();
  return const [
    'socketexception',
    'connection refused',
    'connection timed out',
    'connection error',
    'connectiontimeout',
    'connection reset',
    'network is unreachable',
    'no route to host',
    'failed host lookup',
    'timed out',
    'timeout',
  ].any(t.contains);
}

class VpsProfileHealthNotifier extends Notifier<Map<int, VpsProfileHealth>> {
  var _loaded = false;

  @override
  Map<int, VpsProfileHealth> build() {
    unawaited(_load());
    return const {};
  }

  Future<void> _load() async {
    try {
      final raw = await preferences.getVpsProfileHealth();
      if (raw == null || !ref.mounted) return;
      final json = jsonDecode(raw);
      if (json is! Map) return;
      final loaded = <int, VpsProfileHealth>{
        for (final MapEntry(:key, :value) in json.entries)
          if (int.tryParse('$key') case final id? when value is Map)
            id: VpsProfileHealth.fromJson(value.cast<String, Object?>()),
      };
      // What happened while loading is newer than what was saved.
      state = {...loaded, ...state};
    } catch (_) {
    } finally {
      _loaded = true;
    }
  }

  void _put(int id, VpsProfileHealth? health) {
    state = health == null ? ({...state}..remove(id)) : {...state, id: health};
    if (!_loaded) return;
    unawaited(
      preferences
          .setVpsProfileHealth(
            jsonEncode({
              for (final e in state.entries) '${e.key}': e.value.toJson(),
            }),
          )
          .catchError((Object _) {}),
    );
  }

  VpsProfileHealth? of(int id) => state[id];

  void forget(int id) {
    if (state.containsKey(id)) _put(id, null);
  }

  Future<VpsProfileHealth> succeeded(int id, VpsProfileSnapshot before) async {
    final after = await vpsReadSnapshot(id);
    final now = DateTime.now();
    final old = state[id];
    final changed =
        before.digest == null ||
        after.digest == null ||
        before.digest != after.digest;
    final was = before.nodes?.toSet() ?? const <String>{};
    final nodesAfter = after.nodes ?? const <String>[];
    final added = before.nodes == null
        ? const <String>[]
        : [
            for (final n in nodesAfter)
              if (!was.contains(n)) n,
          ];
    final removed = before.nodes == null || after.nodes == null
        ? 0
        : was.difference(nodesAfter.toSet()).length;
    final health = VpsProfileHealth(
      at: now,
      added: changed ? added : old?.added ?? const [],
      removed: changed ? removed : 0,
      changed: changed,
      changedAt: changed ? now : old?.changedAt,
    );
    _put(id, health);
    return health;
  }

  VpsProfileHealth failed(int id, Object error, String message) {
    final now = DateTime.now();
    final old = state[id];
    final health = VpsProfileHealth(
      at: now,
      ok: false,
      error: message,
      unreachable: vpsUnreachable(error),
      failingSince: old != null && !old.ok ? old.failingSince ?? now : now,
      failures: old != null && !old.ok ? old.failures + 1 : 1,
      added: old?.added ?? const [],
      changedAt: old?.changedAt,
    );
    _put(id, health);
    return health;
  }
}

final vpsProfileHealthProvider =
    NotifierProvider<VpsProfileHealthNotifier, Map<int, VpsProfileHealth>>(
      VpsProfileHealthNotifier.new,
    );

String _names(BuildContext context, List<String> names) {
  const shown = 3;
  final head = names.take(shown).join(tr(context, '、', ', '));
  return names.length > shown ? tr(context, '$head 等', '$head and more') : head;
}

String vpsUpdateResultText(
  BuildContext context,
  String label,
  VpsProfileHealth h,
) {
  if (!h.ok) {
    return tr(
      context,
      '「$label」更新失败：${h.error ?? ''}',
      '"$label" did not update: ${h.error ?? ''}',
    );
  }
  if (!h.changed) {
    return tr(
      context,
      '「$label」已是最新，没有变化',
      '"$label" is up to date; nothing changed',
    );
  }
  final parts = <String>[
    if (h.added.isNotEmpty)
      tr(
        context,
        '新增 ${h.added.length} 个节点：${_names(context, h.added)}',
        '${h.added.length} new nodes: ${_names(context, h.added)}',
      ),
    if (h.removed > 0) tr(context, '去掉 ${h.removed} 个', '${h.removed} removed'),
  ];
  return parts.isEmpty
      ? tr(
          context,
          '「$label」已更新，节点没有增减',
          '"$label" updated; same nodes as before',
        )
      : tr(context, '「$label」已更新，', '"$label" updated: ') +
            parts.join(tr(context, '，', '; '));
}

String _span(BuildContext context, Duration d) => d.inDays >= 1
    ? tr(context, '${d.inDays} 天', '${d.inDays} d')
    : d.inHours >= 1
    ? tr(context, '${d.inHours} 小时', '${d.inHours} h')
    : tr(
        context,
        '${d.inMinutes.clamp(1, 59)} 分钟',
        '${d.inMinutes.clamp(1, 59)} min',
      );

/// The card's status for a failing subscription, or null when it is fine.
String? vpsFailingText(BuildContext context, VpsProfileHealth? h) {
  if (h == null || h.ok) return null;
  final now = DateTime.now();
  if (h.deadAt(now)) {
    return tr(
      context,
      '订阅地址可能已停用（已 ${_span(context, now.difference(h.failingSince!))}连不上）。现有线路仍可用，请向提供者要新链接后点"替换链接"',
      'The subscription address may be gone (unreachable for '
          '${_span(context, now.difference(h.failingSince!))}). Your lines '
          'still work; ask your provider for a new link, then tap Replace link',
    );
  }
  final since = h.failingSince == null
      ? null
      : _span(context, now.difference(h.failingSince!));
  if (h.unreachable) {
    return since == null || h.failures < 2
        ? tr(
            context,
            '订阅地址这次没连上，现有线路仍可用，稍后会再试',
            'The subscription address did not answer this time; your lines still work and it is tried again later',
          )
        : tr(
            context,
            '订阅地址连不上（已 $since），现有线路仍可用',
            'The subscription address has not answered for $since; your lines still work',
          );
  }
  return tr(
    context,
    '上次更新失败：${h.error ?? ''}',
    'The last update failed: ${h.error ?? ''}',
  );
}

String vpsUpdateErrorText(Object error) =>
    userFacingErrorMessage(error, currentAppLocalizations);
