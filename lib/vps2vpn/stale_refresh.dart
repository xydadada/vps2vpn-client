// vps2vpn: a dead line may only have moved address; fetch the subscription
// once, quietly, before calling it dead.

import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/home.dart' show mainGroup;
import 'package:fl_clash/vps2vpn/kit.dart' show tr;
import 'package:fl_clash/vps2vpn/profile_health.dart';
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
