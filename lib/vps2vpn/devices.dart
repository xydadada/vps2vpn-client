// vps2vpn: the devices on one account. This device checks in while it is
// connected; the owner can remove a device, and can cut off every other one
// by moving the account to a new link.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/ui.dart' show QrCodeView;
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart'
    show AlertDialog, ButtonStyle, TextButton;

enum VpsDeviceOutcome {
  ok,
  featureOff,
  notFound,
  rateLimited,
  rejected,
  unreachable,
  maybeDone,
}

/// A path under `<sub>/api/`, with a JSON body for a POST.
typedef VpsDeviceCall =
    Future<(int, String, String?)> Function(
      String path, {
      Map<String, Object?>? body,
      Map<String, String> headers,
    });

Map<String, Object?> _json(String text) {
  try {
    final json = jsonDecode(text);
    return json is Map<String, Object?> ? json : const {};
  } on FormatException {
    return const {};
  }
}

VpsDeviceOutcome vpsDeviceOutcome(int code, Map<String, Object?> body) =>
    switch (code) {
      HttpStatus.ok => VpsDeviceOutcome.ok,
      HttpStatus.serviceUnavailable when body['code'] == 'feature_off' =>
        VpsDeviceOutcome.featureOff,
      HttpStatus.notFound => VpsDeviceOutcome.notFound,
      HttpStatus.tooManyRequests => VpsDeviceOutcome.rateLimited,
      >= 400 && < 500 => VpsDeviceOutcome.rejected,
      _ => VpsDeviceOutcome.unreachable,
    };

Future<(VpsDeviceOutcome, Map<String, Object?>)> _ask(
  VpsDeviceCall call,
  String path, {
  Map<String, Object?>? body,
  Map<String, String> headers = const {},
}) async {
  try {
    final (code, text, _) = await call(path, body: body, headers: headers);
    final json = _json(text);
    return (vpsDeviceOutcome(code, json), json);
  } catch (_) {
    return (VpsDeviceOutcome.unreachable, const <String, Object?>{});
  }
}

final _uuidShape = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

String vpsNewDeviceId([Random? random]) {
  final r = random ?? Random.secure();
  final b = [for (var i = 0; i < 16; i++) r.nextInt(256)];
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final hex = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

Future<String?> Function(String key) vpsDeviceLoad = preferences.getVpsDevice;
Future<void> Function(String key, String value) vpsDeviceSave =
    preferences.setVpsDevice;

String? _deviceId;

/// Made once and kept in this user's own settings, so each account on a
/// shared computer is its own device.
Future<String> vpsDeviceId() async {
  if (_deviceId != null) return _deviceId!;
  final stored = (await vpsDeviceLoad('Id'))?.toLowerCase();
  if (stored != null && _uuidShape.hasMatch(stored)) return _deviceId = stored;
  final made = vpsNewDeviceId();
  await vpsDeviceSave('Id', made);
  return _deviceId = made;
}

String vpsDevicePlatform() => switch (Platform.operatingSystem) {
  'windows' ||
  'android' ||
  'macos' ||
  'linux' ||
  'ios' => Platform.operatingSystem,
  _ => 'linux',
};

String vpsDeviceName({String? host, String? platform}) {
  final os = platform ?? vpsDevicePlatform();
  var name = (host ?? _hostName()).trim();
  if (name.isEmpty || name == 'localhost') name = vpsPlatformLabel(os);
  final runes = name.runes.toList();
  return runes.length > 40 ? String.fromCharCodes(runes.take(40)) : name;
}

String _hostName() {
  try {
    return Platform.localHostname;
  } catch (_) {
    return '';
  }
}

String vpsPlatformLabel(String platform) => switch (platform) {
  'windows' => 'Windows',
  'android' => 'Android',
  'macos' => 'macOS',
  'linux' => 'Linux',
  'ios' => 'iOS',
  _ => platform,
};

Map<String, Object?> vpsCheckInBody({
  required String id,
  required String version,
  String? name,
  String? platform,
}) {
  final os = platform ?? vpsDevicePlatform();
  return {
    'device_id': id,
    'name': name ?? vpsDeviceName(platform: os),
    'platform': os,
    'version': version.length > 32 ? version.substring(0, 32) : version,
  };
}

/// One check-in: a removal marks this subscription and disconnects; the
/// owner taking it back, or turning the feature off, clears the mark. Other
/// answers (a rate limit, no network) change nothing.
Future<VpsDeviceOutcome> vpsDeviceBeat({
  required VpsDeviceCall call,
  required Map<String, Object?> body,
  required void Function(bool removed) mark,
  required FutureOr<void> Function() disconnect,
}) async {
  final (outcome, json) = await _ask(call, 'device', body: body);
  switch (outcome) {
    case VpsDeviceOutcome.ok:
      final removed = json['revoked'] == true;
      mark(removed);
      if (removed) await disconnect();
    case VpsDeviceOutcome.featureOff:
      mark(false);
    default:
  }
  return outcome;
}

class VpsDevice {
  const VpsDevice({
    required this.id,
    required this.name,
    required this.platform,
    this.version = '',
    this.firstSeen,
    this.lastSeen,
    this.ip = '',
    this.revoked = false,
    this.thisDevice = false,
  });

  final String id;
  final String name;
  final String platform;
  final String version;
  final DateTime? firstSeen;
  final DateTime? lastSeen;
  final String ip;
  final bool revoked;
  final bool thisDevice;

  static VpsDevice? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['device_id'];
    if (id is! String || id.isEmpty || id.length > 64) return null;
    return VpsDevice(
      id: id,
      name: '${json['name'] ?? ''}',
      platform: '${json['platform'] ?? ''}',
      version: '${json['version'] ?? ''}',
      firstSeen: vpsPanelTime(json['first_seen']),
      lastSeen: vpsPanelTime(json['last_seen']),
      ip: '${json['ip'] ?? ''}',
      revoked: json['revoked'] == true,
      thisDevice: json['this_device'] == true,
    );
  }
}

typedef VpsDeviceList = ({
  VpsDeviceOutcome outcome,
  List<VpsDevice> devices,
  int onlineIps,
  int maxIps,
});

int _count(Object? v) => v is int && v >= 0 ? v : 0;

Future<VpsDeviceList> vpsListDevices(VpsDeviceCall call, String ownId) async {
  final (outcome, json) = await _ask(
    call,
    'devices',
    headers: {'X-V2V-Device': ownId},
  );
  final list = json['devices'];
  return (
    outcome: outcome,
    devices: outcome == VpsDeviceOutcome.ok && list is List
        ? [for (final d in list) ?VpsDevice.fromJson(d)]
        : const <VpsDevice>[],
    onlineIps: _count(json['online_ips']),
    maxIps: _count(json['max_ips']),
  );
}

Future<VpsDeviceOutcome> vpsSetDeviceRemoved(
  VpsDeviceCall call,
  String id, {
  required bool removed,
}) async {
  final path =
      'devices/${Uri.encodeComponent(id)}/${removed ? 'revoke' : 'unrevoke'}';
  return (await _ask(call, path, body: const {})).$1;
}

/// The new link the panel handed out, on [base]'s own host: `sub_url` when it
/// is one, else built from `base` (`/s/<token>/`).
String? vpsKickLink(Uri base, Map<String, Object?> json) {
  bool ours(String url) {
    final api = vpsApiBase(url);
    return api != null && api.host == base.host && api.port == base.port;
  }

  final sub = json['sub_url'];
  if (sub is String && ours(sub)) return sub.trim();
  final path = json['base'];
  if (path is! String) return null;
  final segs = path.split('/').where((s) => s.isNotEmpty).toList();
  if (segs.length != 2 || segs[0] != 's') return null;
  final built = base.replace(pathSegments: ['s', segs[1], '']).toString();
  return ours(built) ? built : null;
}

typedef VpsKickResult = ({
  VpsDeviceOutcome outcome,
  String? link,
  bool switched,
});

/// 128 random bits, base64url without padding: 22 characters.
String vpsNewRequestId([Random? random]) {
  final r = random ?? Random.secure();
  return base64Url
      .encode([for (var i = 0; i < 16; i++) r.nextInt(256)])
      .replaceAll('=', '');
}

const vpsKickReplayWindow = Duration(minutes: 10);

typedef VpsKickPending = ({
  int profileId,
  String oldUrl,
  String requestId,
  DateTime at,
});

Future<VpsKickPending?> vpsLoadKickPending() async {
  try {
    final j = jsonDecode(await vpsDeviceLoad('Kick') ?? '');
    if (j is! Map) return null;
    final (id, url, request, at) = (
      j['profile'],
      j['url'],
      j['request'],
      j['at'],
    );
    if (id is! int || url is! String || request is! String || at is! int) {
      return null;
    }
    return (
      profileId: id,
      oldUrl: url,
      requestId: request,
      at: DateTime.fromMillisecondsSinceEpoch(at),
    );
  } catch (_) {
    return null;
  }
}

Future<void> vpsSaveKickPending(VpsKickPending? p) => vpsDeviceSave(
  'Kick',
  p == null
      ? ''
      : jsonEncode({
          'profile': p.profileId,
          'url': p.oldUrl,
          'request': p.requestId,
          'at': p.at.millisecondsSinceEpoch,
        }),
);

/// The old link dies the moment the panel answers, so the new one is taken
/// on before it is fetched: a fetch that fails leaves this device on the new
/// link with a retry, never on the dead one. No answer is sent again with the
/// same [requestId], which the panel replays; a 404 to a resend means the
/// replay is gone.
Future<VpsKickResult> vpsKickOthers({
  required VpsDeviceCall call,
  required Uri base,
  required String ownId,
  required String requestId,
  required void Function(String link) adopt,
  required Future<void> Function() refetch,
  bool resumed = false,
  List<Duration> backoff = const [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ],
  Future<void> Function(Duration) wait = Future<void>.delayed,
}) async {
  var resent = resumed;
  VpsDeviceOutcome outcome;
  Map<String, Object?> json;
  for (var i = 0; ; i++) {
    (outcome, json) = await _ask(
      call,
      'devices/kick-others',
      body: {'device_id': ownId, 'request_id': requestId},
    );
    if (outcome == VpsDeviceOutcome.notFound && resent) {
      outcome = VpsDeviceOutcome.maybeDone;
    }
    if (outcome != VpsDeviceOutcome.unreachable || i >= backoff.length) break;
    resent = true;
    await wait(backoff[i]);
  }
  if (outcome != VpsDeviceOutcome.ok) {
    return (outcome: outcome, link: null, switched: false);
  }
  final link = vpsKickLink(base, json);
  if (link == null) {
    return (outcome: VpsDeviceOutcome.rejected, link: null, switched: false);
  }
  adopt(link);
  try {
    await refetch();
  } catch (_) {
    return (outcome: VpsDeviceOutcome.ok, link: link, switched: false);
  }
  return (outcome: VpsDeviceOutcome.ok, link: link, switched: true);
}

var _kicking = false;

/// What is in flight stays on disk until the panel has answered, so a
/// restart within [vpsKickReplayWindow] sends the same request again.
Future<VpsKickResult?> vpsRunKick({
  required VpsDeviceCall call,
  required Profile profile,
  required void Function(Profile moved) put,
  required Future<void> Function(Profile moved) update,
  VpsKickPending? resume,
  Future<void> Function(Duration) wait = Future<void>.delayed,
}) async {
  final base = vpsApiBase(profile.url);
  if (base == null || _kicking) return null;
  _kicking = true;
  try {
    final pending =
        resume ??
        (
          profileId: profile.id,
          oldUrl: profile.url,
          requestId: vpsNewRequestId(),
          at: DateTime.now(),
        );
    if (resume == null) await vpsSaveKickPending(pending);
    Profile? moved;
    final result = await vpsKickOthers(
      call: call,
      base: base,
      ownId: await vpsDeviceId(),
      requestId: pending.requestId,
      resumed: resume != null,
      wait: wait,
      adopt: (link) {
        moved = profile.copyWith(url: link);
        put(moved!);
      },
      refetch: () => update(moved!),
    );
    if (result.outcome != VpsDeviceOutcome.unreachable) {
      await vpsSaveKickPending(null);
    }
    return result;
  } finally {
    _kicking = false;
  }
}

/// A sign-out cut short by a restart or a dead network goes on by itself.
final vpsKickResumeProvider = Provider.autoDispose<void>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  ref.watch(isStartProvider);
  final calls = ref.read(vpsDeviceCallsProvider);
  final profiles = ref.read(profilesProvider);
  final put = ref.read(profilesProvider.notifier).put;
  final actions = ref.read(profilesActionProvider.notifier);
  unawaited(() async {
    final pending = await vpsLoadKickPending();
    if (pending == null) return;
    final profile = profiles.getProfile(pending.profileId);
    final base = vpsApiBase(pending.oldUrl);
    final context = globalState.navigatorKey.currentContext;
    if (profile == null || profile.url != pending.oldUrl || base == null) {
      await vpsSaveKickPending(null);
      return;
    }
    if (DateTime.now().difference(pending.at) > vpsKickReplayWindow) {
      await vpsSaveKickPending(null);
      if (context != null && context.mounted) {
        dialogs.showBanner(_outcomeText(context, VpsDeviceOutcome.maybeDone));
      }
      return;
    }
    final result = await vpsRunKick(
      call: calls(base),
      profile: profile,
      put: put,
      update: actions.updateProfile,
      resume: pending,
    );
    final now = globalState.navigatorKey.currentContext;
    if (result == null || now == null || !now.mounted) return;
    final link = result.link;
    if (link == null) {
      if (result.outcome != VpsDeviceOutcome.unreachable) {
        dialogs.showBanner(_outcomeText(now, result.outcome));
      }
      return;
    }
    unawaited(
      dialogs.showQrCode(
        title: tr(now, '其他设备已下线，本机已换上新链接', 'Other devices signed out'),
        data: link,
        message: tr(
          now,
          '其他设备如需继续使用，请扫码或复制这条新链接重新导入。',
          'This device is on a new link. Scan or copy it on any other device '
              'you still use.',
        ),
      ),
    );
  }());
});

Future<String?> Function() vpsRemovedLoad = () => vpsDeviceLoad('Removed');
Future<void> Function(String) vpsRemovedSave = (value) =>
    vpsDeviceSave('Removed', value);

/// Subscriptions (by profile id) whose owner removed this device.
class VpsRemoved extends Notifier<Set<int>> {
  @override
  Set<int> build() {
    unawaited(_load());
    return const {};
  }

  Future<void> _load() async {
    try {
      final raw = await vpsRemovedLoad();
      if (raw == null || !ref.mounted) return;
      final list = jsonDecode(raw);
      if (list is List) state = {...state, ...list.whereType<int>()};
    } catch (_) {}
  }

  void mark(int profileId, bool removed) {
    if (state.contains(profileId) == removed) return;
    state = removed ? {...state, profileId} : ({...state}..remove(profileId));
    unawaited(vpsRemovedSave(jsonEncode(state.toList())).catchError((_) {}));
  }
}

final vpsRemovedProvider = NotifierProvider<VpsRemoved, Set<int>>(
  VpsRemoved.new,
);

VpsDeviceCall vpsDeviceCallFor(Ref ref, Uri base) =>
    (path, {body, headers = const {}}) async {
      final route = await vpsPanelRoute(ref, base);
      return vpsPanelCall(
        base.resolve(path),
        body: body,
        headers: headers,
        proxyPort: route.port,
        proxyAuth: route.auth,
        pinnedSha256: route.pins,
      );
    };

/// For widgets: panel calls made through a provider that stays alive.
final vpsDeviceCallsProvider = Provider<VpsDeviceCall Function(Uri base)>(
  (ref) =>
      (base) => vpsDeviceCallFor(ref, base),
);

final _beatAt = <int, DateTime>{};

/// On connect and every 30 minutes while connected, on our own panel with
/// the feature on.
final vpsDeviceSyncProvider = Provider.autoDispose<void>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  final on = ref.watch(isStartProvider) && !ref.watch(suspendProvider);
  final feature = ref.watch(
    vpsMemberProvider.select((s) => s.value?.member?.devices ?? false),
  );
  final profile = ref.watch(
    currentProfileProvider.select(
      (p) => p == null || p.type != ProfileType.url ? null : (p.id, p.url),
    ),
  );
  if (!on || !feature || profile == null) return;
  final (profileId, url) = profile;
  final base = vpsApiBase(url);
  if (base == null) return;
  final call = vpsDeviceCallFor(ref, base);
  final removed = ref.read(vpsRemovedProvider.notifier);
  Future<void> beat() async {
    final last = _beatAt[profileId];
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(seconds: 10)) {
      return;
    }
    _beatAt[profileId] = now;
    var told = false;
    await vpsDeviceBeat(
      call: call,
      body: vpsCheckInBody(
        id: await vpsDeviceId(),
        version: globalState.packageInfo.version,
      ),
      mark: (r) {
        told = r && !ref.read(vpsRemovedProvider).contains(profileId);
        removed.mark(profileId, r);
      },
      disconnect: () async {
        if (!ref.mounted || !ref.read(isStartProvider)) return;
        await globalState.safeRun(
          () => ref.read(setupActionProvider.notifier).setRunning(false),
        );
      },
    );
    if (!told) return;
    final context = globalState.navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    dialogs.showBanner(vpsRemovedText(context));
  }

  unawaited(beat());
  final timer = Timer.periodic(
    const Duration(minutes: 30),
    (_) => unawaited(beat()),
  );
  ref.onDispose(timer.cancel);
});

String vpsRemovedText(BuildContext context) =>
    tr(context, '此设备已被账号所有者移除', 'This device was removed by the owner');

String _ago(BuildContext context, DateTime? at) {
  if (at == null) return '';
  final d = DateTime.now().difference(at);
  if (d.inMinutes < 2) return tr(context, '刚刚', 'just now');
  if (d.inHours < 1) {
    return tr(context, '${d.inMinutes} 分钟前', '${d.inMinutes} min ago');
  }
  if (d.inDays < 1) {
    return tr(context, '${d.inHours} 小时前', '${d.inHours} h ago');
  }
  return tr(context, '${d.inDays} 天前', '${d.inDays} d ago');
}

String _outcomeText(BuildContext context, VpsDeviceOutcome outcome) =>
    switch (outcome) {
      VpsDeviceOutcome.ok => '',
      VpsDeviceOutcome.featureOff => tr(
        context,
        '账号所有者没有开启设备管理',
        'The account owner has device management off',
      ),
      VpsDeviceOutcome.notFound => tr(
        context,
        '找不到这台设备或订阅链接已失效',
        'No such device, or the subscription link no longer works',
      ),
      VpsDeviceOutcome.rateLimited => tr(
        context,
        '操作太频繁了，过一会儿再试',
        'Too many tries; wait a while and try again',
      ),
      VpsDeviceOutcome.rejected => tr(
        context,
        '服务器没有接受这个操作',
        'The server refused it',
      ),
      VpsDeviceOutcome.unreachable => tr(
        context,
        '现在连不上服务器，稍后再试',
        'The server is out of reach; try again later',
      ),
      VpsDeviceOutcome.maybeDone => tr(
        context,
        '可能已经生效，请到会员页查看新链接',
        'It may have gone through; look for the new link on the member page',
      ),
    };

Future<void> _copyRestoreNote(BuildContext context) async {
  final id = await vpsDeviceId();
  if (!context.mounted) return;
  final name = vpsDeviceName();
  await Clipboard.setData(
    ClipboardData(
      text: tr(
        context,
        '请在 vps2vpn 面板的设备管理里恢复这台设备：$name（${vpsPlatformLabel(vpsDevicePlatform())}，${id.substring(0, 8)}）',
        'Please restore this device under Devices in the vps2vpn panel: '
            '$name (${vpsPlatformLabel(vpsDevicePlatform())}, '
            '${id.substring(0, 8)})',
      ),
    ),
  );
  if (!context.mounted) return;
  dialogs.showBanner(
    tr(
      context,
      '已复制，请发给账号所有者恢复此设备',
      'Copied; send it to the owner to restore this device',
    ),
  );
}

class VpsDeviceRemovedNotice extends ConsumerWidget {
  const VpsDeviceRemovedNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider);
    if (profile == null ||
        !ref.watch(vpsRemovedProvider).contains(profile.id)) {
      return const SizedBox.shrink();
    }
    final p = VpsPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: VpsCard(
        highlight: true,
        padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                VpsIconView(VpsIcon.shield, size: 19, color: p.bad),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    vpsRemovedText(context),
                    style: vpsText(p, size: 14, weight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              tr(
                context,
                '此设备已被移除，这个订阅在本机已停用。账号所有者恢复后即可重新连接。',
                'This device was removed, so this subscription is off here '
                    'until the owner restores it; then connect again.',
              ),
              style: vpsText(p, size: 13, color: p.soft, height: 1.5),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                VpsButton(
                  label: tr(context, '联系所有者恢复', 'Ask the owner to restore'),
                  filled: true,
                  onTap: () => unawaited(_copyRestoreNote(context)),
                ),
                VpsButton(
                  label: tr(context, '移除这个订阅', 'Remove this subscription'),
                  onTap: () => unawaited(_removeProfile(ref, profile.id)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _removeProfile(WidgetRef ref, int profileId) async {
  final context = globalState.navigatorKey.currentContext;
  if (context == null || !await vpsAskRemoveProfile(context)) return;
  await ref.read(profilesActionProvider.notifier).deleteProfile(profileId);
  ref.read(vpsRemovedProvider.notifier).mark(profileId, false);
}

Future<bool> vpsAskRemoveProfile(BuildContext context) async =>
    await dialogs.showMessage(
      title: tr(context, '移除这个订阅？', 'Remove this subscription?'),
      message: TextSpan(
        text: tr(
          context,
          '只删除本机上的这个订阅，账号不受影响。',
          'Only this device forgets the subscription; the account is not '
              'affected.',
        ),
      ),
      confirmText: tr(context, '移除', 'Remove'),
      destructive: true,
    ) ==
    true;

/// [sample] stands in for the panel's answer in screenshots.
Future<void> vpsShowDevices({
  bool confirmKick = false,
  VpsDeviceList? sample,
}) => dialogs.showCommonDialog<void>(
  child: _DevicesDialog(confirmKick: confirmKick, sample: sample),
);

class VpsDevicesRow extends ConsumerWidget {
  const VpsDevicesRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feature = ref.watch(
      vpsMemberProvider.select((s) => s.value?.member?.devices ?? false),
    );
    final id = ref.watch(currentProfileProvider.select((p) => p?.id));
    if (!feature || id == null) return const SizedBox.shrink();
    final removed = ref.watch(vpsRemovedProvider).contains(id);
    final p = VpsPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: VpsCard(
        child: VpsRow(
          icon: VpsIcon.shield,
          title: tr(context, '设备管理', 'Devices'),
          subtitle: removed
              ? vpsRemovedText(context)
              : tr(
                  context,
                  '看看哪些设备在用这个账号，移除不认识的',
                  'See which devices use this account; remove strangers',
                ),
          trailing: VpsIconView(VpsIcon.chevron, size: 16, color: p.muted),
          onTap: () => unawaited(vpsShowDevices()),
        ),
      ),
    );
  }
}

class _DevicesDialog extends ConsumerStatefulWidget {
  const _DevicesDialog({this.confirmKick = false, this.sample});

  final bool confirmKick;
  final VpsDeviceList? sample;

  @override
  ConsumerState<_DevicesDialog> createState() => _DevicesDialogState();
}

class _DevicesDialogState extends ConsumerState<_DevicesDialog> {
  Future<VpsDeviceList>? _list;
  var _busy = false;
  var _listed = false;
  late var _confirming = widget.confirmKick;
  String? _error;
  VpsKickResult? _kicked;

  VpsDeviceCall? _call() {
    final base = vpsApiBase(ref.read(currentProfileProvider)?.url ?? '');
    return base == null ? null : ref.read(vpsDeviceCallsProvider)(base);
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    if (widget.sample case final sample?) {
      _list = Future.value(sample);
      _listed = true;
      return;
    }
    final call = _call();
    if (call == null) return;
    final list = _list = vpsDeviceId().then((id) => vpsListDevices(call, id));
    _listed = false;
    unawaited(
      list.then((l) {
        if (mounted && _list == list) {
          setState(() => _listed = l.outcome == VpsDeviceOutcome.ok);
        }
      }),
    );
  }

  Future<void> _run(Future<String?> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await action();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      _reload();
    });
  }

  Future<void> _setRemoved(VpsDevice device, bool removed) => _run(() async {
    final call = _call();
    if (call == null) return null;
    final outcome = await vpsSetDeviceRemoved(
      call,
      device.id,
      removed: removed,
    );
    if (!mounted || outcome == VpsDeviceOutcome.ok) return null;
    return _outcomeText(context, outcome);
  });

  Future<void> _kick() async {
    setState(() => _confirming = false);
    await _run(() async {
      final profile = ref.read(currentProfileProvider);
      final base = vpsApiBase(profile?.url ?? '');
      if (profile == null || base == null) return null;
      final result = await vpsRunKick(
        call: ref.read(vpsDeviceCallsProvider)(base),
        profile: profile,
        put: ref.read(profilesProvider.notifier).put,
        update: ref.read(profilesActionProvider.notifier).updateProfile,
      );
      if (!mounted || result == null) return null;
      if (result.link != null) {
        setState(() => _kicked = result);
        return null;
      }
      if (result.outcome == VpsDeviceOutcome.unreachable) {
        return tr(
          context,
          '没收到服务器的回答。10 分钟内重新连接或重开软件时会自动接着发，不会再换一次链接',
          'No answer from the server. It is sent again by itself when you '
              'reconnect or reopen the app within 10 minutes, without a '
              'second new link',
        );
      }
      return _outcomeText(context, result.outcome);
    });
  }

  Future<void> _retry() => _run(() async {
    final profile = ref.read(currentProfileProvider);
    if (profile == null) return null;
    try {
      await ref.read(profilesActionProvider.notifier).updateProfile(profile);
    } catch (_) {
      if (!mounted) return null;
      return _outcomeText(context, VpsDeviceOutcome.unreachable);
    }
    if (mounted && _kicked != null) {
      setState(
        () => _kicked = (
          outcome: VpsDeviceOutcome.ok,
          link: _kicked!.link,
          switched: true,
        ),
      );
    }
    return null;
  });

  Widget _kickedView(VpsPalette p, VpsKickResult kicked) {
    final link = kicked.link!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          kicked.switched
              ? tr(
                  context,
                  '其他设备都已下线，本机已换上新链接。其他设备如需继续使用，请重新导入新链接。',
                  'Every other device is signed out and this one is on the '
                      'new link. Import the new link on any device you still '
                      'use.',
                )
              : tr(
                  context,
                  '其他设备都已下线，本机已换上新链接，但新订阅还没下载下来（网络不通）。请点击「重试」。',
                  'Every other device is signed out and this one is on the '
                      'new link, but the new subscription has not downloaded '
                      'yet (no network). ${Platform.isAndroid ? 'Tap' : 'Click'} '
                      '"Retry".',
                ),
          style: vpsText(p, size: 13, color: p.soft, height: 1.5),
        ),
        if (QrCodeView.fits(link)) ...[
          const SizedBox(height: 12),
          Center(child: QrCodeView(data: link, size: 200)),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            if (!kicked.switched)
              VpsButton(
                label: tr(context, '重试', 'Retry'),
                filled: true,
                onTap: _busy ? null : () => unawaited(_retry()),
              ),
            VpsButton(
              label: tr(context, '复制新链接', 'Copy the new link'),
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: link));
                if (!mounted) return;
                dialogs.showBanner(tr(context, '新链接已复制', 'New link copied'));
              },
            ),
            VpsButton(
              label: tr(context, '显示二维码', 'Show QR code'),
              onTap: () => unawaited(
                dialogs.showQrCode(
                  title: tr(context, '新链接', 'New link'),
                  data: link,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _deviceRow(VpsPalette p, VpsDevice d) {
    final meta = [
      vpsPlatformLabel(d.platform),
      if (d.version.isNotEmpty) 'v${d.version}',
      if (d.ip.isNotEmpty) d.ip,
      _ago(context, d.lastSeen),
    ].where((s) => s.isNotEmpty).toList();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Opacity(
              opacity: d.revoked ? 0.55 : 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [
                      d.name.isEmpty ? vpsPlatformLabel(d.platform) : d.name,
                      if (d.thisDevice) tr(context, '（本机）', ' (this device)'),
                      if (d.revoked) tr(context, '（已移除）', ' (removed)'),
                    ].join(),
                    style: vpsText(p, size: 14, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  // Wraps between the parts, never inside "12 分钟前".
                  Wrap(
                    children: [
                      for (final (i, part) in meta.indexed)
                        Text(
                          i == meta.length - 1 ? part : '$part · ',
                          softWrap: false,
                          style: vpsText(p, size: 12, color: p.muted),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (!d.thisDevice)
            VpsButton(
              label: d.revoked
                  ? tr(context, '恢复', 'Restore')
                  : tr(context, '移除', 'Remove'),
              onTap: _busy ? null : () => unawaited(_setRemoved(d, !d.revoked)),
            ),
        ],
      ),
    );
  }

  Widget _skeleton(VpsPalette p) {
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: ShapeDecoration(
        color: p.track,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(height / 2),
        ),
      ),
    );
    return Semantics(
      label: tr(context, '正在读取', 'Loading'),
      child: VpsBreathe(
        active: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final width in const [150.0, 120.0, 170.0])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          bar(width, 14),
                          const SizedBox(height: 6),
                          bar(width + 60, 10),
                        ],
                      ),
                    ),
                    bar(52, 30),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final kicked = _kicked;
    if (_confirming && kicked == null) {
      return AlertDialog(
        title: tr(context, '让其他设备下线？', 'Sign out other devices?'),
        destructive: true,
        actions: [
          TextButton(
            onPressed: () => setState(() => _confirming = false),
            child: Text(tr(context, '取消', 'Cancel')),
          ),
          TextButton(
            onPressed: () => unawaited(_kick()),
            child: Text(tr(context, '下线', 'Sign out')),
          ),
        ],
        child: Text(
          tr(
            context,
            '其他设备（包括手机上的其他软件）会立即断开，需要重新导入新链接才能继续使用。',
            'Every other device, other apps on phones included, disconnects '
                'at once and needs the new link imported to keep working.',
          ),
        ),
      );
    }
    return AlertDialog(
      title: tr(context, '设备管理', 'Devices'),
      destructive: kicked == null,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr(context, '关闭', 'Close')),
        ),
        if (kicked == null)
          TextButton(
            style: ButtonStyle(
              foregroundColor: WidgetStateProperty<Color?>.fromMap({
                WidgetState.disabled: p.bad.withValues(alpha: 0.38),
                WidgetState.any: p.bad,
              }),
            ),
            onPressed: _busy || !_listed
                ? null
                : () => setState(() => _confirming = true),
            child: Text(tr(context, '让其他设备下线', 'Sign out other devices')),
          ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                Text(_error!, style: vpsText(p, size: 13, color: p.bad)),
                const SizedBox(height: 8),
              ],
              if (kicked != null)
                _kickedView(p, kicked)
              else
                FutureBuilder<VpsDeviceList>(
                  future: _list,
                  builder: (context, snap) {
                    final list = snap.data;
                    if (list == null) return _skeleton(p);
                    if (list.outcome != VpsDeviceOutcome.ok) {
                      return Text(
                        _outcomeText(context, list.outcome),
                        style: vpsText(p, size: 13, color: p.soft),
                      );
                    }
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (list.maxIps > 0)
                          Text(
                            tr(
                              context,
                              '在线 IP ${list.onlineIps} / 最多 ${list.maxIps}',
                              'Online IPs ${list.onlineIps} of ${list.maxIps}',
                            ),
                            style: vpsText(p, size: 13, color: p.soft).copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        for (final d in list.devices) _deviceRow(p, d),
                      ],
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
