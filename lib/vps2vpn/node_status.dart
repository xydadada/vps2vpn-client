// vps2vpn: our panel's word on its servers, down for maintenance or crowded.

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum VpsNodeState { ok, maintenance, congested }

class VpsNodeStatus {
  const VpsNodeStatus({
    required this.group,
    required this.names,
    required this.state,
    this.id = '',
    this.note = '',
    this.until,
  });

  final String id;
  final String group;
  final List<String> names;
  final VpsNodeState state;
  final String note;
  final DateTime? until;

  static VpsNodeStatus? fromJson(
    Object? json, {
    DateTime? Function(Object?)? at,
  }) {
    if (json is! Map) return null;
    final names = json['names'];
    if (names is! List) return null;
    final note = json['note'] is String ? (json['note'] as String).trim() : '';
    return VpsNodeStatus(
      id: '${json['id'] ?? ''}',
      group: '${json['group'] ?? ''}',
      names: [
        for (final name in names)
          if (name is String && name.isNotEmpty) name,
      ],
      state: switch (json['state']) {
        'maintenance' => VpsNodeState.maintenance,
        'congested' => VpsNodeState.congested,
        _ => VpsNodeState.ok,
      },
      note: note.runes.length > 100
          ? String.fromCharCodes(note.runes.take(100))
          : note,
      until: at?.call(json['until']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is VpsNodeStatus &&
      other.id == id &&
      other.group == group &&
      other.state == state &&
      other.note == note &&
      other.until == until &&
      const ListEquality<String>().equals(other.names, names);

  @override
  int get hashCode => Object.hash(id, group, state, note, until);
}

Map<String, VpsNodeStatus> vpsNodeStatusByName(List<VpsNodeStatus> nodes) => {
  for (final node in nodes)
    if (node.state != VpsNodeState.ok)
      for (final name in node.names) name: node,
};

/// The last word from the panel; it outlives a failed fetch, so a panel
/// that is briefly out of reach does not undo it.
class VpsNodeStatusNotifier extends Notifier<List<VpsNodeStatus>> {
  @override
  List<VpsNodeStatus> build() => const [];

  bool set(List<VpsNodeStatus> nodes) {
    final kept = [
      for (final node in nodes)
        if (node.state != VpsNodeState.ok) node,
    ];
    if (const ListEquality<VpsNodeStatus>().equals(kept, state)) return false;
    state = kept;
    return true;
  }
}

final vpsNodeStatusProvider =
    NotifierProvider<VpsNodeStatusNotifier, List<VpsNodeStatus>>(
      VpsNodeStatusNotifier.new,
    );

/// The line names the Core's smart and AI lines try last, and next to last.
({List<String> down, List<String> busy}) vpsLinesToAvoid(
  List<VpsNodeStatus> nodes,
) => (
  down: [
    for (final node in nodes)
      if (node.state == VpsNodeState.maintenance) ...node.names,
  ],
  busy: [
    for (final node in nodes)
      if (node.state == VpsNodeState.congested) ...node.names,
  ],
);

String vpsClock(DateTime at, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final hm =
      '${'${at.hour}'.padLeft(2, '0')}:${'${at.minute}'.padLeft(2, '0')}';
  return at.year == today.year && at.month == today.month && at.day == today.day
      ? hm
      : '${at.month}/${at.day} $hm';
}
