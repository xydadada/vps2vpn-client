// vps2vpn member API: the panel the subscription comes from also answers
//   GET  <sub>/api/me      account, usage, expiry, server-side AI check
//   POST <sub>/api/report  "this line keeps failing / works again"
// where <sub> is the imported link https://host:port/s/<token> without its
// query. The token in the path is the only credential.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/datetime.dart';
import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/common/yaml.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/flags.dart';
import 'package:fl_clash/vps2vpn/line_watch.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

export 'line_watch.dart' show VpsLineHealth;

final _token = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

/// `<sub>/api/` for a vps2vpn subscription link, else null.
Uri? vpsApiBase(String subUrl) {
  final uri = Uri.tryParse(subUrl.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return null;
  }
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.length != 2 || segs[0] != 's' || !_token.hasMatch(segs[1])) {
    return null;
  }
  // The member API is served over HTTPS only, on the same host and port,
  // even when the subscription itself is a plain-HTTP link.
  return Uri(
    scheme: 'https',
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
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
      // The panel result is network input: a huge/NaN timestamp must not
      // throw during widget construction.
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
    return u != null && u.isScheme('https') ? u : null;
  }

  static VpsClientRelease? fromJson(Object? json) {
    if (json is! Map) return null;
    final version = '${json['version'] ?? ''}'.trim().replaceFirst(
      RegExp(r'^[vV]+'),
      '',
    );
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
    final n = math.max(a.length, b.length);
    for (var i = 0; i < n; i++) {
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
    bool? unlimited,
    this.expireAt,
    this.ai,
    this.client,
  }) : unlimited = unlimited ?? (quotaGb <= 0);

  final String name;
  final bool enabled;

  /// quota | expired | manual | devices; null when enabled
  final String? disabledReason;
  final int usedUp;
  final int usedDown;

  /// Effective quota in GiB after sharing; see [unlimited] for whether the
  /// member has an unlimited plan (quota_eff can be 0 even on a capped plan).
  final double quotaGb;
  final bool unlimited;
  final DateTime? expireAt;
  final VpsAiStatus? ai;
  final VpsClientRelease? client;

  /// Convert to double before summing, to avoid overflowing signed 64-bit counters.
  double get used =>
      math.max(0, usedUp).toDouble() + math.max(0, usedDown).toDouble();

  /// A zero effective quota may still indicate an exhausted finite plan.
  bool get isLimited => !unlimited;

  double get quotaBytes {
    final bytes = quotaGb * (1024 * 1024 * 1024);
    return bytes.isFinite && bytes > 0 ? bytes : 0;
  }

  static int _int(Object? v) {
    if (v is! num || !v.isFinite || v <= 0) return 0;
    const maxCount = 0x7fffffffffffffff;
    return v >= maxCount ? maxCount : v.toInt();
  }

  factory VpsMember.fromJson(Map<String, Object?> json) {
    final rawQuotaGb = json['quota_gb'];
    final unlimited =
        rawQuotaGb is! num || !rawQuotaGb.isFinite || rawQuotaGb <= 0;
    final quota = json['quota_eff'] ?? rawQuotaGb;
    return VpsMember(
      name: '${json['name'] ?? ''}',
      enabled: json['enabled'] != false,
      disabledReason: switch (json['disabled_reason']) {
        final String r when r.isNotEmpty => r,
        _ => null,
      },
      usedUp: _int(json['used_up']),
      usedDown: _int(json['used_down']),
      quotaGb: quota is num && quota.isFinite && quota > 0
          ? quota.toDouble()
          : 0,
      unlimited: unlimited,
      expireAt: dateTimeFromUnixSeconds(json['expire_at']),
      ai: VpsAiStatus.fromJson(json['ai']),
      client: VpsClientRelease.fromJson(json['client']),
    );
  }
}

/// [member] when the panel answered; [linkChanged] when it said the token
/// is unknown (rotated or removed), so the user has to import the new link.
enum VpsPanelProblem { unavailable, httpsRequired, unreachable }

class VpsMemberResult {
  const VpsMemberResult({this.member, this.linkChanged = false, this.problem});

  final VpsMember? member;
  final bool linkChanged;
  final VpsPanelProblem? problem;

  static VpsMemberResult fromResponse(Uri base, int code, String text) {
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      json = null;
    }
    if (json is Map && json['service'] == 'vps2vpn') {
      if (base.isScheme('https') &&
          code == HttpStatus.unauthorized &&
          json['error'] == 'token_invalid') {
        return const VpsMemberResult(linkChanged: true);
      }
      if (code == HttpStatus.upgradeRequired &&
          json['error'] == 'https_required') {
        return const VpsMemberResult(problem: VpsPanelProblem.httpsRequired);
      }
    }
    // The panel answers an unknown token with a plain 404 (no JSON, so the
    // panel cannot be fingerprinted). Over verified HTTPS that means the
    // link was rotated or removed.
    if (base.isScheme('https') && code == HttpStatus.notFound) {
      return const VpsMemberResult(linkChanged: true);
    }
    if (code == HttpStatus.ok &&
        json is Map<String, Object?> &&
        json['name'] is String &&
        json['enabled'] is bool) {
      return VpsMemberResult(member: VpsMember.fromJson(json));
    }
    return VpsMemberResult(
      problem: code == HttpStatus.notFound || code == HttpStatus.ok
          ? VpsPanelProblem.unavailable
          : VpsPanelProblem.unreachable,
    );
  }
}

class VpsRequestScope {
  final _clients = <HttpClient>{};
  bool _closed = false;

  bool get closed => _closed;

  void attach(HttpClient client) {
    if (_closed) {
      client.close(force: true);
      throw const HttpException('Panel request cancelled');
    }
    _clients.add(client);
  }

  void detach(HttpClient client) => _clients.remove(client);

  void close() {
    _closed = true;
    final clients = [..._clients];
    _clients.clear();
    for (final client in clients) {
      client.close(force: true);
    }
  }
}

const _maxPanelResponseBytes = 256 * 1024;
const _maxPinProfileBytes = 2 << 20;
final _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

(int, DateTime?, String)? _pinCacheKey;
Set<String> _pinCacheValue = const {};

String _normHost(String host) {
  var h = host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']') && h.length > 2) {
    h = h.substring(1, h.length - 1);
  }
  return h;
}

String? _normFingerprint(Object? value) {
  if (value is! String) return null;
  final clean = value.trim().replaceAll(':', '').toLowerCase();
  return _sha256Hex.hasMatch(clean) ? clean : null;
}

void _collectPin(
  Map<dynamic, dynamic> def,
  String targetHost,
  Set<String> out,
) {
  if (_normHost('${def['server'] ?? ''}') != targetHost) return;
  final fp = _normFingerprint(def['fingerprint']);
  if (fp != null) out.add(fp);
}

Future<Set<String>> _pinnedFromProfileFile(
  int? profileId,
  DateTime? updatedAt,
  String host,
) async {
  if (profileId == null || Platform.environment.containsKey('FLUTTER_TEST')) {
    return const {};
  }
  final targetHost = _normHost(host);
  if (targetHost.isEmpty) return const {};
  final key = (profileId, updatedAt, targetHost);
  if (_pinCacheKey == key) return _pinCacheValue;
  final pins = <String>{};
  try {
    final path = await appPath.getProfilePath(profileId.toString());
    final file = File(path);
    if (await file.exists() && await file.length() <= _maxPinProfileBytes) {
      final doc = loadPlainYaml(await file.readAsString());
      if (doc is Map) {
        final proxies = doc['proxies'];
        if (proxies is List) {
          for (final item in proxies) {
            if (item is Map) _collectPin(item, targetHost, pins);
          }
        }
      }
    }
  } catch (_) {}
  final result = Set<String>.unmodifiable(pins);
  _pinCacheKey = key;
  _pinCacheValue = result;
  return result;
}

Future<Set<String>> _pinnedFromCore(Ref ref, String host) async {
  if (ref.read(coreStatusProvider) != CoreStatus.connected) return const {};
  final targetHost = _normHost(host);
  if (targetHost.isEmpty) return const {};
  final core = ref.read(coreHandlerProvider);
  final groups = ref.read(groupsProvider);
  final seen = <String>{};
  final pins = <String>{};
  for (final group in groups) {
    for (final proxy in group.all) {
      if (!seen.add(proxy.name)) continue;
      try {
        final def = await core.getProxyDefinition(proxy.name);
        if (!ref.mounted) return const {};
        if (def != null) _collectPin(def, targetHost, pins);
      } catch (_) {}
    }
  }
  return pins;
}

Future<Set<String>> _pinnedSha256ForProfile(
  Ref ref,
  int? profileId,
  DateTime? updatedAt,
  String host,
) async {
  final pins = await _pinnedFromProfileFile(profileId, updatedAt, host);
  if (pins.isNotEmpty || !ref.mounted) return pins;
  return _pinnedFromCore(ref, host);
}

Future<String> _readBoundedUtf8(
  Stream<List<int>> stream, {
  int maxBytes = _maxPanelResponseBytes,
}) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (builder.length + chunk.length > maxBytes) {
      throw const HttpException('Panel response too large');
    }
    builder.add(chunk);
  }
  return utf8.decode(builder.takeBytes(), allowMalformed: true);
}

HttpClient _client({
  int? proxyPort,
  String? proxyAuth,
  Uri? base,
  Set<String> pinnedSha256 = const {},
}) {
  final normalizedPins = pinnedSha256.isEmpty
      ? const <String>{}
      : {
          for (final p in pinnedSha256)
            p.trim().replaceAll(':', '').toLowerCase(),
        };
  final c = HttpClient()
    ..badCertificateCallback = (cert, host, port) {
      if (normalizedPins.isEmpty || base == null) return false;
      final expectedPort = base.hasPort ? base.port : 443;
      if (_normHost(host) != _normHost(base.host) || port != expectedPort) {
        return false;
      }
      final digest = sha256.convert(cert.der).toString().toLowerCase();
      return normalizedPins.contains(digest);
    }
    ..connectionTimeout = const Duration(seconds: 6)
    ..idleTimeout = const Duration(seconds: 2);
  final userInfo = proxyAuth != null && proxyAuth.isNotEmpty
      ? '$proxyAuth@'
      : '';
  c.findProxy = (_) =>
      proxyPort == null ? 'DIRECT' : 'PROXY ${userInfo}127.0.0.1:$proxyPort';
  return c;
}

Future<(int, String)> _send(
  Uri url, {
  Map<String, Object?>? body,
  int? proxyPort,
  String? proxyAuth,
  VpsRequestScope? scope,
  Set<String> pinnedSha256 = const {},
}) async {
  final client = _client(
    proxyPort: proxyPort,
    proxyAuth: proxyAuth,
    base: url,
    pinnedSha256: pinnedSha256,
  );
  try {
    scope?.attach(client);
    final req = body == null
        ? await client.getUrl(url).timeout(const Duration(seconds: 10))
        : await client.postUrl(url).timeout(const Duration(seconds: 10));
    req.followRedirects = false;
    if (body != null) {
      // A fixed length, not chunked: the panel's server cannot read chunks.
      final bytes = utf8.encode(jsonEncode(body));
      req.headers
        ..set('X-V2V', '1')
        ..contentType = ContentType.json
        ..contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close().timeout(const Duration(seconds: 10));
    final text = await _readBoundedUtf8(
      res,
    ).timeout(const Duration(seconds: 10));
    return (res.statusCode, text);
  } finally {
    scope?.detach(client);
    client.close(force: true);
  }
}

/// Direct first, like the subscription fetch; through our own proxy when
/// direct fails and [proxyPort] is given.
Future<VpsMemberResult?> fetchMember(
  Uri base, {
  int? proxyPort,
  String? proxyAuth,
  VpsRequestScope? scope,
  Set<String> pinnedSha256 = const {},
}) async {
  VpsMemberResult? result;
  var sawHandshake = false;
  var sawOtherError = false;
  for (final port in [null, ?proxyPort]) {
    if (scope?.closed == true) return null;
    try {
      final (code, text) = await _send(
        base.resolve('me'),
        proxyPort: port,
        proxyAuth: port == null ? null : proxyAuth,
        scope: scope,
        pinnedSha256: pinnedSha256,
      );
      if (scope?.closed == true) return null;
      result = VpsMemberResult.fromResponse(base, code, text);
      if (result.member != null ||
          result.linkChanged ||
          result.problem == VpsPanelProblem.httpsRequired) {
        return result;
      }
    } on HandshakeException {
      sawHandshake = true;
    } catch (_) {
      sawOtherError = true;
    }
  }
  if (scope?.closed == true) return null;
  if (result != null) return result;
  if (sawHandshake && !sawOtherError) {
    return const VpsMemberResult(problem: VpsPanelProblem.httpsRequired);
  }
  return const VpsMemberResult(problem: VpsPanelProblem.unreachable);
}

/// Always direct: the line being reported is the one that is down.
Future<bool> reportLine(
  Uri base, {
  required String line,
  required bool ok,
  required String host,
  VpsRequestScope? scope,
  Set<String> pinnedSha256 = const {},
}) async {
  try {
    final (code, _) = await _send(
      base.resolve('report'),
      body: {'line': line, 'ok': ok, 'host': host},
      scope: scope,
      pinnedSha256: pinnedSha256,
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

/// The signed-in member for the current subscription, or null when it is
/// not a vps2vpn link.
final vpsMemberProvider = FutureProvider.autoDispose<VpsMemberResult?>((
  ref,
) async {
  final (profileId, url, updatedAt) = ref.watch(
    currentProfileProvider.select(
      (p) => (p?.id, p?.url ?? '', p?.lastUpdateDate),
    ),
  );
  final base = vpsApiBase(url);
  if (base == null) return null;
  final on = ref.watch(isStartProvider) && !ref.watch(suspendProvider);
  final port = on
      ? ref.watch(patchClashConfigProvider.select((p) => p.mixedPort))
      : null;
  final proxyAuth = on
      ? () {
          final auth = ref.watch(
            networkSettingProvider.select((s) => s.authentication),
          );
          if (!auth.enable || auth.username.isEmpty) return null;
          return '${Uri.encodeComponent(auth.username)}:'
              '${Uri.encodeComponent(auth.password)}';
        }()
      : null;
  final scope = VpsRequestScope();
  Timer? timer;
  var listening = true;
  var visible = ref.read(appVisibleProvider);
  var finished = false;
  DateTime? fetchedAt;
  var interval = const Duration(minutes: 5);
  void schedule() {
    timer?.cancel();
    if (!listening || !visible || !finished || !ref.mounted) return;
    final elapsed = fetchedAt == null
        ? Duration.zero
        : DateTime.now().difference(fetchedAt);
    final remaining = interval - elapsed;
    if (remaining <= Duration.zero) {
      ref.invalidateSelf();
    } else {
      timer = Timer(remaining, ref.invalidateSelf);
    }
  }

  ref.listen(appVisibleProvider, (_, next) {
    if (visible == next) return;
    visible = next;
    if (!visible) {
      timer?.cancel();
    } else {
      schedule();
    }
  });
  ref.onCancel(() {
    listening = false;
    timer?.cancel();
  });
  ref.onResume(() {
    listening = true;
    schedule();
  });
  ref.onDispose(() {
    timer?.cancel();
    scope.close();
  });
  final pins = await _pinnedSha256ForProfile(
    ref,
    profileId,
    updatedAt,
    base.host,
  );
  if (!ref.mounted || scope.closed) return null;
  final result = await fetchMember(
    base,
    proxyPort: port,
    proxyAuth: proxyAuth,
    scope: scope,
    pinnedSha256: pins,
  );
  if (result?.problem == VpsPanelProblem.unreachable) {
    interval = const Duration(seconds: 30);
  }
  fetchedAt = DateTime.now();
  finished = true;
  schedule();
  return result;
});

final vpsLineWatchProvider = Provider.autoDispose<void>((ref) {
  if (ref.watch(safeModeProvider) ||
      Platform.environment.containsKey('FLUTTER_TEST') ||
      !ref.watch(isStartProvider) ||
      ref.watch(suspendProvider) ||
      ref.watch(coreStatusProvider) != CoreStatus.connected) {
    return;
  }
  final (profileId, url, updatedAt) = ref.watch(
    currentProfileProvider.select(
      (p) => (p?.id, p?.url ?? '', p?.lastUpdateDate),
    ),
  );
  final base = vpsApiBase(url);
  if (base == null) return;
  final core = ref.watch(coreHandlerProvider);
  final scope = VpsRequestScope();
  final targetHost = _normHost(base.host);
  var pinnedSha256 = const <String>{};
  final watch = VpsLineWatch(
    lines: () async {
      if (!await ref.read(setupActionProvider.notifier).inputsApplied() ||
          !ref.mounted) {
        return null;
      }
      final groups = ref.read(groupsProvider);
      if (groups.isEmpty) return null;
      final smart = groups
          .where((g) => g.name == vpsSmartGroupName)
          .firstOrNull;
      final fallback =
          groups
              .where((g) => g.type == GroupType.Selector && g.hidden != true)
              .firstOrNull ??
          groups.first;
      final candidates = smart != null
          ? [smart]
          : [
              fallback,
              for (final g in groups)
                if (g.name != fallback.name) g,
            ];
      final lines = <VpsWatchedLine>[];
      final pins = <String>{
        ...await _pinnedFromProfileFile(profileId, updatedAt, base.host),
      };
      if (!ref.mounted) return null;
      final seen = <String>{};
      for (final group in candidates) {
        final testUrl = group.testUrl ?? defaultTestUrl;
        for (final proxy in group.all) {
          if (!seen.add(proxy.name)) continue;
          final def = await core.getProxyDefinition(proxy.name);
          if (!ref.mounted) return null;
          if (def == null) continue;
          _collectPin(def, targetHost, pins);
          final kind = vpsLineKind(def);
          final rawHost = '${def['server'] ?? ''}'.trim();
          final host = _normHost(rawHost);
          if (kind == null || host.isEmpty || host.contains(':')) continue;
          lines.add(
            VpsWatchedLine(
              name: proxy.name,
              kind: kind,
              host: rawHost,
              testUrl: testUrl,
            ),
          );
        }
        // When the smart group or main selector already yielded leaf lines,
        // stop rather than scanning auxiliary groups.
        if (smart != null || lines.isNotEmpty) break;
      }
      pinnedSha256 = Set<String>.unmodifiable(pins);
      return lines;
    },
    probe: (line) async {
      final delay = await core.testDelay(
        TestDelayParams(
          proxyName: line.name,
          testUrl: line.testUrl,
          timeout: 5000,
        ),
      );
      return (delay.value ?? -1) > 0;
    },
    report: (line, ok) => reportLine(
      base,
      line: line.kind,
      ok: ok,
      host: line.host,
      scope: scope,
      pinnedSha256: pinnedSha256,
    ),
  );
  ref.onDispose(() {
    watch.dispose();
    scope.close();
  });
  watch.start();
});

/// Certificate pins for the current subscription's panel host (the leaf
/// certificate its Hysteria2/TUIC entries pin), empty when there are none.
final vpsPanelPinsProvider = FutureProvider.autoDispose<Set<String>>((
  ref,
) async {
  final (profileId, url, updatedAt) = ref.watch(
    currentProfileProvider.select(
      (p) => (p?.id, p?.url ?? '', p?.lastUpdateDate),
    ),
  );
  final base = vpsApiBase(url);
  if (base == null) return const {};
  return _pinnedSha256ForProfile(ref, profileId, updatedAt, base.host);
});

final _releaseFileName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
const _maxReleaseBytes = 512 * 1024 * 1024;

/// Downloads a client release from the panel into [dir], always direct and
/// over HTTPS. A self-signed panel is trusted only through [pinnedSha256],
/// like /api/me, so the browser's certificate warning never comes up.
Future<File> vpsDownloadRelease(
  Uri url,
  Directory dir, {
  Set<String> pinnedSha256 = const {},
}) async {
  if (!url.isScheme('https')) {
    throw const HttpException('Release link is not HTTPS');
  }
  final name = url.pathSegments.isEmpty ? '' : url.pathSegments.last;
  if (!_releaseFileName.hasMatch(name)) {
    throw const HttpException('Unexpected release file name');
  }
  final client = _client(base: url, pinnedSha256: pinnedSha256);
  final part = File('${dir.path}${Platform.pathSeparator}$name.part');
  try {
    final req = await client.getUrl(url);
    req.followRedirects = false;
    final res = await req.close().timeout(const Duration(seconds: 15));
    if (res.statusCode != HttpStatus.ok) {
      await res.drain<void>();
      throw HttpException('Download failed (HTTP ${res.statusCode})');
    }
    final sink = part.openWrite();
    var size = 0;
    try {
      await for (final chunk in res.timeout(const Duration(seconds: 60))) {
        size += chunk.length;
        if (size > _maxReleaseBytes) {
          throw const HttpException('Release file too large');
        }
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    final out = File('${dir.path}${Platform.pathSeparator}$name');
    if (await out.exists()) await out.delete();
    return await part.rename(out.path);
  } catch (_) {
    if (await part.exists()) await part.delete();
    rethrow;
  } finally {
    client.close(force: true);
  }
}
