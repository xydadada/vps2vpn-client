// vps2vpn: a dead line may only have moved address; fetch the subscription
// once, quietly, before calling it dead.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/home.dart' show mainGroup;
import 'package:fl_clash/vps2vpn/flags.dart';
import 'package:fl_clash/vps2vpn/kit.dart' show tr;
import 'package:fl_clash/vps2vpn/node_status.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:fl_clash/vps2vpn/profile_health.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _freshEnough = Duration(minutes: 10);
const _between = Duration(minutes: 30);

final _triedAt = <int, DateTime>{};

bool vpsShouldRefresh({
  required DateTime now,
  required DateTime? updatedAt,
  required DateTime? triedAt,
}) =>
    (updatedAt == null || now.difference(updatedAt) >= _freshEnough) &&
    (triedAt == null || now.difference(triedAt) >= _between);

final vpsStaleRefreshProvider = Provider.autoDispose<void>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  if (!ref.watch(isStartProvider) || ref.watch(suspendProvider)) return;
  final profile = ref.watch(currentProfileProvider);
  if (profile == null || profile.type != ProfileType.url) return;
  final group = mainGroup(ref.watch(currentGroupsStateProvider).value);
  if (group == null) return;
  final delay = ref.watch(
    delayProvider(proxyName: group.name, testUrl: group.testUrl),
  );
  if (delay == null || delay >= 0) return;
  final now = DateTime.now();
  if (!vpsShouldRefresh(
    now: now,
    updatedAt: profile.lastUpdateDate,
    triedAt: _triedAt[profile.id],
  )) {
    return;
  }
  _triedAt[profile.id] = now;
  final action = ref.read(profilesActionProvider.notifier);
  final health = ref.read(vpsProfileHealthProvider.notifier);
  unawaited(() async {
    try {
      await action.updateProfile(profile);
    } catch (_) {
      return;
    }
    final h = health.of(profile.id);
    if (h == null || !h.ok || !h.changed) return;
    final context = globalState.navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    dialogs.showBanner(
      tr(
        context,
        '线路没有响应，订阅里的线路地址已变更，已自动更新',
        'The line stopped answering; its address had changed in the '
            'subscription, which was updated by itself',
      ),
    );
  }());
});

/// A top-up or renewal since: the header and its Announce line are stale.
bool vpsHeaderBehindPanel(SubscriptionInfo sub, VpsMember m) {
  final total = m.unlimited ? 0 : math.max(1, (m.quotaGb * (1 << 30)).floor());
  final expire = (m.expireAt?.millisecondsSinceEpoch ?? 0) ~/ 1000;
  return (sub.total - total).abs() > (1 << 20) ||
      (sub.expire - expire).abs() > 60;
}

final _syncedAt = <int, DateTime>{};

final vpsPanelSyncProvider = Provider.autoDispose<void>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  final member = ref.watch(vpsMemberProvider).value?.member;
  final profile = ref.watch(currentProfileProvider);
  final sub = profile?.subscriptionInfo;
  if (member == null ||
      profile == null ||
      sub == null ||
      profile.type != ProfileType.url ||
      !vpsHeaderBehindPanel(sub, member)) {
    return;
  }
  final now = DateTime.now();
  final last = _syncedAt[profile.id];
  if (last != null && now.difference(last) < const Duration(hours: 1)) return;
  _syncedAt[profile.id] = now;
  unawaited(
    ref
        .read(profilesActionProvider.notifier)
        .updateProfile(profile)
        .catchError((Object _) {}),
  );
});

/// Fetches the subscription when the panel's [version] is not the one the
/// last fetch went with, and remembers it only once that fetch succeeded.
Future<bool> vpsFollowConfigVersion({
  required String version,
  required Future<String?> Function() load,
  required Future<void> Function(String) save,
  required Future<void> Function() update,
}) async {
  if (await load() == version) return false;
  await update();
  await save(version);
  return true;
}

final _configBusy = <int>{};
final _configTriedAt = <int, DateTime>{};

final vpsConfigVersionSyncProvider = Provider.autoDispose<void>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  final version = ref.watch(
    vpsMemberProvider.select((s) => s.value?.member?.configVersion),
  );
  final profile = ref.watch(currentProfileProvider);
  if (version == null ||
      profile == null ||
      profile.type != ProfileType.url ||
      _configBusy.contains(profile.id)) {
    return;
  }
  final now = DateTime.now();
  final tried = _configTriedAt[profile.id];
  if (tried != null && now.difference(tried) < const Duration(minutes: 1)) {
    return;
  }
  _configBusy.add(profile.id);
  final action = ref.read(profilesActionProvider.notifier);
  unawaited(
    vpsFollowConfigVersion(
          version: version,
          load: () => preferences.getVpsConfigVersion(profile.id),
          save: (v) => preferences.setVpsConfigVersion(profile.id, v),
          update: () async {
            _configTriedAt[profile.id] = DateTime.now();
            await action.updateProfile(profile);
          },
        )
        .catchError((Object _) => false)
        .whenComplete(() => _configBusy.remove(profile.id)),
  );
});

final _toldDown = <String>{};

/// The panel's word on its servers reaches the Core, and the smart line is
/// rebuilt around a server going into or out of maintenance.
final vpsNodeStatusSyncProvider = Provider.autoDispose<void>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  final result = ref.watch(vpsMemberProvider);
  if (result.isLoading) return;
  final member = result.value?.member;
  if (member == null) return;
  final nodes = member.nodes ?? const <VpsNodeStatus>[];
  scheduleMicrotask(() {
    if (!ref.mounted) return;
    if (!ref.read(vpsNodeStatusProvider.notifier).set(nodes)) return;
    if (!ref.read(isStartProvider)) return;
    ref.read(setupActionProvider.notifier).applyProfileDebounce(force: true);
    final group = mainGroup(ref.read(currentGroupsStateProvider).value);
    final picked = group == null
        ? null
        : ref.read(selectedProxyNameProvider(group.name));
    final down = vpsNodeStatusByName(ref.read(vpsNodeStatusProvider))[picked];
    if (picked == null ||
        picked == vpsSmartGroupName ||
        down?.state != VpsNodeState.maintenance ||
        !_toldDown.add('$picked|${down!.until}')) {
      return;
    }
    final context = globalState.navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    dialogs.showBanner(vpsMaintenanceText(context, picked, down));
  });
});

String vpsMaintenanceText(
  BuildContext context,
  String name,
  VpsNodeStatus status,
) {
  final until = status.until;
  final back = until == null ? '' : vpsClock(until);
  final note = status.note.isEmpty ? '' : '：${status.note}';
  return tr(
    context,
    '$name 在维护$note${back.isEmpty ? '' : '（预计 $back 恢复）'}。照样可以连，连不上就到「节点」换一条或改用智能线路。',
    '$name is down for maintenance'
        '${status.note.isEmpty ? '' : ': ${status.note}'}'
        '${back.isEmpty ? '' : ' (back about $back)'}. You can still use it; '
        'if it does not answer, pick another in Nodes or use the smart line.',
  );
}
