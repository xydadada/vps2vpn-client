// vps2vpn member API: the panel the subscription comes from also answers
//   GET  <sub>/api/me      account, usage, expiry, server-side AI check
//   POST <sub>/api/report  "this line keeps failing / works again"
// where <sub> is the imported link https://host:port/s/<token> without its
// query. The token in the path is the only credential.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/datetime.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/flags.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final _token = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

/// `<sub>/api/` for a vps2vpn subscription link, else null.
Uri? vpsApiBase(String subUrl) {
  final uri = Uri.tryParse(subUrl.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      !(uri.isScheme('http') || uri.isScheme('https'))) {
    return null;
  }
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.length != 2 || segs[0] != 's' || !_token.hasMatch(segs[1])) {
    return null;
  }
  return Uri(
    scheme: 'https',
    host: uri.host,
    port: uri.port,
    pathSegments: ['s', segs[1], 'api', ''],
  );
}

/// What the server itself sees when it opens the AI sites.
class VpsAiStatus {
  const VpsAiStatus({
    required this.summary,
    this.place,
    this.at,
    this.sites = const {},
  });

  final String summary;
  final String? place;
  final DateTime? at;

  /// claude, claude_api, chatgpt, gemini → ok | blocked | unreachable | unknown
  final Map<String, String> sites;

  static VpsAiStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'];
    final sites = json['sites'];
    return VpsAiStatus(
      summary: '${json['summary'] ?? ''}',
      place: json['place'] is String ? json['place'] as String : null,
      at: dateTimeFromUnixSeconds(at),
      sites: sites is Map
          ? {for (final e in sites.entries) '${e.key}': '${e.value}'}
          : const {},
    );
  }
}

/// A newer client the owner published on the panel (optional).
class VpsClientRelease {
  const VpsClientRelease({
    required this.version,
    required this.url,
    this.notes,
    this.files = const {},
  });

  final String version;

  /// What "download" opens when there is no file for this platform.
  final Uri url;
  final String? notes;

  /// Platform (windows, android, macos, linux) → installer on the panel.
  final Map<String, Uri> files;

  static Uri? _web(Object? v) {
    final u = Uri.tryParse('${v ?? ''}');
    return u != null && (u.isScheme('http') || u.isScheme('https')) ? u : null;
  }

  static VpsClientRelease? fromJson(Object? json) {
    if (json is! Map) return null;
    final version = '${json['version'] ?? ''}'.trim().replaceFirst('v', '');
    final raw = json['files'];
    final files = <String, Uri>{
      if (raw is Map)
        for (final e in raw.entries)
          if (_web(e.value) case final u?) '${e.key}'.toLowerCase(): u,
    };
    final url = _web(json['url']) ?? files.values.firstOrNull;
    if (version.isEmpty || url == null) return null;
    final notes = json['notes'];
    return VpsClientRelease(
      version: version,
      url: url,
      notes: notes is String && notes.trim().isNotEmpty ? notes.trim() : null,
      files: files,
    );
  }

  /// The installer for [platform] when the panel has one, else [url].
  Uri downloadFor(String platform) => files[platform] ?? url;

  /// True when this release is newer than [current]; false when either
  /// version is not plain numbers.
  bool newerThan(String current) {
    List<int>? parse(String v) {
      final parts = v.split('+').first.split('.');
      final nums = parts.map(int.tryParse).toList();
      return nums.contains(null) ? null : nums.cast<int>();
    }

    final a = parse(version);
    final b = parse(current);
    if (a == null || b == null) return false;
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}

class VpsMember {
  const VpsMember({
    required this.name,
    required this.enabled,
    this.disabledReason,
    this.usedUp = 0,
    this.usedDown = 0,
    this.quotaGb = 0,
    this.expireAt,
    this.ai,
    this.client,
  });

  final String name;
  final bool enabled;

  /// quota | expired | manual | devices; null when enabled
  final String? disabledReason;
  final int usedUp;
  final int usedDown;

  /// What applies after sharing; 0 = unlimited.
  final double quotaGb;
  final DateTime? expireAt;
  final VpsAiStatus? ai;
  final VpsClientRelease? client;

  int get used => usedUp + usedDown;

  static int _int(Object? v) => v is num ? v.toInt() : 0;

  factory VpsMember.fromJson(Map<String, Object?> json) {
    final quota = json['quota_eff'] ?? json['quota_gb'];
    return VpsMember(
      name: '${json['name'] ?? ''}',
      enabled: json['enabled'] != false,
      disabledReason: switch (json['disabled_reason']) {
        final String r when r.isNotEmpty => r,
        _ => null,
      },
      usedUp: _int(json['used_up']),
      usedDown: _int(json['used_down']),
      quotaGb: quota is num ? quota.toDouble() : 0,
      expireAt: dateTimeFromUnixSeconds(json['expire_at']),
      ai: VpsAiStatus.fromJson(json['ai']),
      client: VpsClientRelease.fromJson(json['client']),
    );
  }
}

/// [member] when the panel answered; [linkChanged] when it said the token
/// is unknown (rotated or removed), so the user has to import the new link.
class VpsMemberResult {
  const VpsMemberResult({this.member, this.linkChanged = false});

  final VpsMember? member;
  final bool linkChanged;
}

HttpClient _client(
  Uri url, {
  int? proxyPort,
  String? proxyCredentials,
  Set<String> certificatePins = const {},
}) {
  final c = HttpClient(
    context: certificatePins.isEmpty
        ? null
        : SecurityContext(withTrustedRoots: false),
  )
    ..badCertificateCallback = (certificate, host, port) =>
        host.toLowerCase() == url.host.toLowerCase() &&
        port == url.port &&
        certificatePins.contains(sha256.convert(certificate.der).toString())
    ..connectionTimeout = const Duration(seconds: 6)
    ..idleTimeout = const Duration(seconds: 2);
  c.findProxy = (_) =>
      proxyPort == null ? 'DIRECT' : 'PROXY 127.0.0.1:$proxyPort';
  final credentials = proxyCredentials;
  final separator = credentials?.indexOf(':') ?? -1;
  if (proxyPort != null && credentials != null && separator > 0) {
    var attempted = false;
    c.authenticateProxy = (host, port, scheme, realm) async {
      if (attempted ||
          host != '127.0.0.1' ||
          port != proxyPort ||
          scheme.toLowerCase() != 'basic') {
        return false;
      }
      attempted = true;
      c.addProxyCredentials(
        host,
        port,
        realm ?? '',
        HttpClientBasicCredentials(
          credentials.substring(0, separator),
          credentials.substring(separator + 1),
        ),
      );
      return true;
    };
  }
  return c;
}

Future<String> _responseText(HttpClientResponse response) async {
  const limit = 1024 * 1024;
  if (response.contentLength > limit) {
    throw const FormatException('Panel response is too large');
  }
  final bytes = <int>[];
  await for (final chunk in response) {
    if (bytes.length + chunk.length > limit) {
      throw const FormatException('Panel response is too large');
    }
    bytes.addAll(chunk);
  }
  return utf8.decode(bytes);
}

Future<(int, String)> _send(
  Uri url, {
  Map<String, Object?>? body,
  int? proxyPort,
  String? proxyCredentials,
  Set<String> certificatePins = const {},
}) async {
  final client = _client(
    url,
    proxyPort: proxyPort,
    proxyCredentials: proxyCredentials,
    certificatePins: certificatePins,
  );
  try {
    final req = body == null
        ? await client.getUrl(url)
        : await client.postUrl(url);
    req.followRedirects = false;
    if (body != null) {
      // Keep the small JSON request bounded by an explicit body length.
      final bytes = utf8.encode(jsonEncode(body));
      req.headers
        ..set('X-V2V', '1')
        ..contentType = ContentType.json
        ..contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close().timeout(const Duration(seconds: 10));
    final text = await _responseText(
      res,
    ).timeout(const Duration(seconds: 10));
    return (res.statusCode, text);
  } finally {
    client.close(force: true);
  }
}

/// Direct first, like the subscription fetch; through our own proxy when
/// direct fails and [proxyPort] is given.
Future<VpsMemberResult?> fetchMember(
  Uri base, {
  int? proxyPort,
  String? proxyCredentials,
  Set<String> certificatePins = const {},
}) async {
  for (final port in [null, ?proxyPort]) {
    try {
      final (code, text) = await _send(
        base.resolve('me'),
        proxyPort: port,
        proxyCredentials: proxyCredentials,
        certificatePins: certificatePins,
      );
      if (code == HttpStatus.notFound) {
        return const VpsMemberResult(linkChanged: true);
      }
      if (code != HttpStatus.ok) continue;
      final json = jsonDecode(text);
      if (json is! Map<String, Object?>) continue;
      return VpsMemberResult(member: VpsMember.fromJson(json));
    } catch (_) {}
  }
  return null;
}

/// Always direct: the line being reported is the one that is down.
Future<bool> reportLine(
  Uri base, {
  required String line,
  required bool ok,
  required String host,
  Set<String> certificatePins = const {},
}) async {
  try {
    final (code, _) = await _send(
      base.resolve('report'),
      body: {'line': line, 'ok': ok, 'host': host},
      certificatePins: certificatePins,
    );
    return code == HttpStatus.ok;
  } catch (_) {
    return false;
  }
}

/// reality | hy2 | tuic for a node definition, else null.
String? vpsLineKind(Map<String, dynamic> def) {
  return switch ('${def['type']}'.toLowerCase()) {
    'hysteria2' => 'hy2',
    'tuic' => 'tuic',
    'vless' when def['reality-opts'] != null => 'reality',
    _ => null,
  };
}

/// One report per change: [threshold] failures in a row → down; the first
/// success after that → up again. Blips in between say nothing.
class VpsLineHealth {
  VpsLineHealth({this.threshold = 3}) : assert(threshold > 0);

  final int threshold;
  final _fails = <String, int>{};
  final _down = <String>{};

  /// false = report down, true = report up, null = nothing to say.
  bool? record(String key, bool ok) {
    if (ok) {
      _fails.remove(key);
      return _down.contains(key) ? true : null;
    }
    final n = (_fails[key] ?? 0) + 1;
    _fails[key] = n < threshold ? n : threshold;
    if (n >= threshold && !_down.contains(key)) return false;
    return null;
  }

  void acknowledge(String key, bool ok) {
    if (ok) {
      _down.remove(key);
    } else {
      _down.add(key);
    }
  }
}

/// Only pins already stored for this exact subscription host may authenticate
/// its self-signed panel. A node on another server grants no trust here.
Set<String> vpsCertificatePins(Uri base, Map<String, dynamic> outbounds) {
  final hosts = outbounds['tls-fingerprints'];
  if (hosts is! Map) return const {};
  final pins = hosts[base.host.toLowerCase()];
  if (pins is! List) return const {};
  return {
    for (final pin in pins)
      if (pin is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(pin)) pin,
  };
}

Future<Set<String>> _profileCertificatePins(
  Ref ref,
  int profileId,
  Uri base,
) async {
  try {
    final outbounds = await ref
        .read(coreHandlerProvider)
        .getProfileOutbounds(profileId);
    return vpsCertificatePins(base, outbounds);
  } catch (_) {
    // A missing pin never disables the normal PKI check.
    return const {};
  }
}

/// The signed-in member for the current subscription, or null when it is
/// not a vps2vpn link (or the panel did not answer).
final vpsMemberProvider = FutureProvider.autoDispose<VpsMemberResult?>((
  ref,
) async {
  final profile = ref.watch(currentProfileProvider);
  final base = vpsApiBase(profile?.url ?? '');
  if (base == null) return null;
  final on = ref.watch(isStartProvider);
  final port = on ? ref.read(patchClashConfigProvider).mixedPort : null;
  final credentials = ref.watch(
    networkSettingProvider.select((state) => state.authentication.credentials),
  );
  final keep = ref.keepAlive();
  // Refresh now and then while someone looks.
  final timer = Timer(const Duration(minutes: 5), () {
    keep.close();
    ref.invalidateSelf();
  });
  ref.onDispose(timer.cancel);
  final pins = await _profileCertificatePins(ref, profile!.id, base);
  if (!ref.mounted) return null;
  return fetchMember(
    base,
    proxyPort: port,
    proxyCredentials: credentials.firstOrNull,
    certificatePins: pins,
  );
});

Timer? _watch;

/// While connected, quietly tests each line of the smart group and tells the
/// panel when one keeps failing (and when it is back), so the owner can move
/// it to a new port. Never in safe mode or tests.
void vpsStartLineWatch(Ref ref) {
  _watch?.cancel();
  if (safeModeBuild ||
      ref.read(safeModeProvider) ||
      Platform.environment.containsKey('FLUTTER_TEST')) {
    return;
  }
  var busy = false;
  Uri? subscription;
  var health = VpsLineHealth();
  _watch = Timer.periodic(const Duration(minutes: 4), (timer) async {
    if (!ref.mounted ||
        ref.read(safeModeProvider) ||
        !ref.read(isStartProvider)) {
      timer.cancel();
      return;
    }
    if (busy) return;
    final base = vpsApiBase(ref.read(currentProfileProvider)?.url ?? '');
    if (base != subscription) {
      subscription = base;
      health = VpsLineHealth();
    }
    if (base == null) return;
    busy = true;
    try {
      await _checkLines(ref, base, timer, health);
    } finally {
      busy = false;
    }
  });
  ref.onDispose(_watch!.cancel);
}

Future<void> _checkLines(
  Ref ref,
  Uri base,
  Timer timer,
  VpsLineHealth health,
) async {
  bool current() =>
      timer.isActive &&
      ref.mounted &&
      !ref.read(safeModeProvider) &&
      ref.read(isStartProvider) &&
      vpsApiBase(ref.read(currentProfileProvider)?.url ?? '') == base;
  if (!current()) return;
  final controller = ref.read(coreHandlerProvider);
  final groups = ref.read(groupsProvider);
  final smart = groups.where((g) => g.name == vpsSmartGroupName).firstOrNull;
  if (smart == null) return;
  final profileId = ref.read(currentProfileProvider)?.id;
  if (profileId == null) return;
  final pins = await _profileCertificatePins(ref, profileId, base);
  if (!current()) return;
  for (final proxy in smart.all) {
    if (!current()) return;
    try {
      final def = await controller.getProxyDefinition(proxy.name);
      if (!current()) return;
      if (def == null) continue;
      final kind = vpsLineKind(def);
      final host = '${def['server'] ?? ''}';
      if (kind == null || host.isEmpty) continue;
      final delay = await controller.testDelay(
        TestDelayParams(
          proxyName: proxy.name,
          testUrl: smart.testUrl ?? defaultTestUrl,
          timeout: 5000,
        ),
      );
      if (!current()) return;
      final ok = (delay.value ?? -1) > 0;
      final key = '$kind@$host';
      final change = health.record(key, ok);
      if (change != null &&
          await reportLine(
            base,
            line: kind,
            ok: change,
            host: host,
            certificatePins: pins,
          )) {
        health.acknowledge(key, change);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('vps2vpn line watch: $e');
    }
  }
}
