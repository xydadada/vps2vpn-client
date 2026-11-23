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
import 'package:fl_clash/common/http.dart';
import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/common/yaml.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/flags.dart';
import 'package:fl_clash/vps2vpn/line_watch.dart';
import 'package:fl_clash/vps2vpn/update_signing.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
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

/// The member centre for a vps2vpn subscription link, else null: the panel
/// serves it at `<sub>/` over HTTPS (asking for more data, inviting a
/// friend). The token in the path signs the member in.
Uri? vpsMemberPage(String subUrl) {
  final base = vpsApiBase(subUrl);
  if (base == null) return null;
  return base.replace(pathSegments: [...base.pathSegments.take(2), '']);
}

/// Where a link to import comes from, for the "import?" question: only the
/// host of a web address, never its path, which holds the subscription's
/// secret. Null for anything else (share links and the like).
String? vpsLinkSource(String link) {
  final uri = Uri.tryParse(link.trim());
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri.host;
}

/// [link] when it is an http(s) address on this PC (127.0.0.1, localhost or
/// ::1), else null.
String? vpsLoopbackLink(String? link) {
  final host = link == null ? null : vpsLinkSource(link);
  const loopback = {'127.0.0.1', 'localhost', '::1'};
  return host != null && loopback.contains(host) ? link!.trim() : null;
}

/// [link] as a subscription: the member centre's own address (`<sub>/`, or
/// `<sub>/index.html`, as copied from the browser) is turned back into the
/// subscription `<sub>`, keeping scheme, port and query. Anything else is
/// returned unchanged.
String vpsSubscriptionLink(String link) {
  final uri = Uri.tryParse(link.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return link;
  }
  final segs = uri.pathSegments;
  // The subscription itself with a page anchor (`<sub>#invites`, copied
  // from the member centre's address bar): the anchor is no part of it.
  if (segs.length == 2 &&
      segs[0] == 's' &&
      _token.hasMatch(segs[1]) &&
      uri.hasFragment) {
    return uri.removeFragment().toString();
  }
  final page =
      segs.length == 3 &&
      segs[0] == 's' &&
      _token.hasMatch(segs[1]) &&
      (segs[2].isEmpty || segs[2] == 'index.html');
  if (!page) return link;
  return uri.replace(pathSegments: segs.take(2)).removeFragment().toString();
}

// Dart DateTime supports at most +/- 8,640,000,000,000,000 ms from epoch.
// Convert only finite in-range *seconds* from remote panel JSON. One corrupt
// optional timestamp must not make the entire member response unusable.
const _maxPanelEpochSeconds = 8640000000000;

DateTime? _panelTimestamp(Object? value) {
  if (value is! num ||
      !value.isFinite ||
      value <= 0 ||
      value > _maxPanelEpochSeconds) {
    return null;
  }
  return DateTime.fromMillisecondsSinceEpoch(value.toInt() * 1000);
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
    final sites = json['sites'];
    return VpsAiStatus(
      summary: '${json['summary'] ?? ''}',
      place: json['place'] is String ? json['place'] as String : null,
      at: _panelTimestamp(json['at']),
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
        for (final e in raw.entries) '${e.key}'.toLowerCase(): ?_web(e.value),
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

  /// The signed installer to fetch for [platform]: the panel's file for it,
  /// else [url] when that is itself a versioned installer built for
  /// [platform] (a panel that only names one link). Null when there is none.
  Uri? installerFor(String platform) {
    final candidate = files[platform] ?? url;
    final name = _lastSegment(candidate).toLowerCase();
    // Check the filename, not just the map key or a later OS-like substring.
    final actualOs = RegExp(
      r'-(windows|android|macos|linux)(?:-|\.)',
    ).firstMatch(name)?.group(1);
    return actualOs == platform && vpsUpdateFileVersion(name) != null
        ? candidate
        : null;
  }

  /// The page the browser opens when there is no installer for [platform]:
  /// [url], unless that is an installer for another platform (which this
  /// device cannot use, so there is nothing to open).
  Uri? pageFor(String platform) {
    if (installerFor(platform) != null) return null;
    return vpsUpdateFileVersion(_lastSegment(url).toLowerCase()) == null
        ? url
        : null;
  }

  static String _lastSegment(Uri u) =>
      u.pathSegments.isEmpty ? '' : u.pathSegments.last;

  /// True when this release is newer than [current]; false when either
  /// version is not plain numbers.
  bool newerThan(String current) => vpsVersionNewer(version, current);
}

/// True when version [a] is newer than [b]; false when either is not plain
/// numbers (a build suffix after `+` is ignored).
bool vpsVersionNewer(String a, String b) {
  List<int>? parse(String v) {
    final parts = v.split('+').first.split('.');
    final nums = parts.map(int.tryParse).toList();
    return nums.contains(null) ? null : nums.cast<int>();
  }

  final x = parse(a);
  final y = parse(b);
  if (x == null || y == null) return false;
  final n = math.max(x.length, y.length);
  for (var i = 0; i < n; i++) {
    final p = i < x.length ? x[i] : 0;
    final q = i < y.length ? y[i] : 0;
    if (p != q) return p > q;
  }
  return false;
}

/// The downloaded installer is not a signed, newer release: it was deleted.
class VpsUpdateRejected implements Exception {
  const VpsUpdateRejected(this.reason);

  /// unsigned | badSignature | notNewer
  final String reason;

  @override
  String toString() => 'VpsUpdateRejected($reason)';
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
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
    this.throttled = false,
    this.limitMbps = 0,
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

  final bool throttled;
  final double limitMbps;

  int get used => usedUp + usedDown;

  // Network JSON is untrusted: malformed/non-finite counters are ignored.
  // Keep converted integers in the portable exact-integer range.
  static int _int(Object? v) =>
      v is num && v.isFinite && v >= 0 && v <= 9007199254740991 ? v.toInt() : 0;

  factory VpsMember.fromJson(Map<String, Object?> json) {
    final expire = _panelTimestamp(json['expire_at']);
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
      quotaGb: quota is num && quota.isFinite ? quota.toDouble() : 0,
      unlimited: unlimited,
      expireAt: expire,
      ai: VpsAiStatus.fromJson(json['ai']),
      client: VpsClientRelease.fromJson(json['client']),
      throttled: json['throttled'] == true,
      limitMbps: switch (json['limit_mbps']) {
        final num v when v.isFinite && v > 0 => v.toDouble(),
        _ => 0,
      },
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

/// One host, whatever its case or IPv6 brackets.
bool vpsSameHost(String a, String b) => _normHost(a) == _normHost(b);

/// Same host and same effective port: the panel's pins vouch for the panel's
/// own listener, not for another service on that machine.
bool vpsSameOrigin(Uri a, Uri b) =>
    a.scheme == b.scheme && vpsSameHost(a.host, b.host) && a.port == b.port;

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

/// The certificate pins a subscription gives for the panel at [host]: its own
/// `x-vps2vpn-pin` (vps2vpn 0.2.13+; a REALITY-only or disabled account's
/// subscription has no Hysteria2/TUIC entry to carry one) and those of its
/// entries on that host.
@visibleForTesting
Set<String> vpsPinsFromProfile(String text, String host) {
  final targetHost = _normHost(host);
  final pins = <String>{};
  final Object? doc;
  try {
    doc = loadPlainYaml(text);
  } catch (_) {
    return pins;
  }
  if (doc is! Map) return pins;
  final own = _normFingerprint(doc['x-vps2vpn-pin']);
  if (own != null) pins.add(own);
  final proxies = doc['proxies'];
  if (proxies is List) {
    for (final item in proxies) {
      if (item is Map) _collectPin(item, targetHost, pins);
    }
  }
  return pins;
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
  final Set<String> pins;
  try {
    final path = await appPath.getProfilePath(profileId.toString());
    final file = File(path);
    pins = await file.exists() && await file.length() <= _maxPinProfileBytes
        ? vpsPinsFromProfile(await file.readAsString(), targetHost)
        : const {};
  } catch (_) {
    // A read that failed (the file being rewritten, say) is not cached: the
    // next request reads it again instead of going without pins until the
    // profile next updates.
    return const {};
  }
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
  // Dart sends the proxy string's user:pass verbatim (it never
  // percent-decodes it), and only that reaches an HTTPS tunnel. What the string
  // cannot carry goes in as credentials, which plain HTTP still answers with.
  var userInfo = '';
  final colon = proxyAuth?.indexOf(':') ?? -1;
  if (proxyPort != null && proxyAuth != null && colon > 0) {
    final user = proxyAuth.substring(0, colon);
    final pass = proxyAuth.substring(colon + 1);
    final raw = FlClashHttpOverrides.pacUserInfo(user, pass);
    if (raw != null) {
      userInfo = '$raw@';
    } else {
      c.addProxyCredentials(
        localhost,
        proxyPort,
        'Basic',
        HttpClientBasicCredentials(user, pass),
      );
    }
  }
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

/// Direct first. When the panel cannot be reached directly (its server's
/// address blocked on this network, say) and [proxyPort] is given, through our
/// own proxy, whose fallback groups have already left the line that is down.
Future<bool> reportLine(
  Uri base, {
  required String line,
  required bool ok,
  required String host,
  int? proxyPort,
  String? proxyAuth,
  VpsRequestScope? scope,
  Set<String> pinnedSha256 = const {},
}) async {
  for (final port in [null, ?proxyPort]) {
    if (scope?.closed == true) return false;
    try {
      final (code, _) = await _send(
        base.resolve('report'),
        body: {'line': line, 'ok': ok, 'host': host},
        proxyPort: port,
        proxyAuth: port == null ? null : proxyAuth,
        scope: scope,
        pinnedSha256: pinnedSha256,
      );
      // The panel answered: another route would get the same answer.
      return code == HttpStatus.ok;
    } catch (_) {}
  }
  return false;
}

/// user:pass for our own mixed port, as typed, when it asks for one. The
/// username cannot hold ':' (the settings page drops it).
String? vpsLocalProxyAuth(AuthenticationProps auth) {
  if (!auth.enable || auth.username.isEmpty) return null;
  return '${auth.username}:${auth.password}';
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

/// A proxy's server address for per-line health reports. Node definitions
/// carry their port separately; accept IPv6 literals but not host:port values.
String? vpsLineReportHost(Map<String, dynamic> def) {
  final raw = def['server'];
  if (raw is! String) return null;
  final host = _normHost(raw);
  if (host.isEmpty) return null;
  if (!host.contains(':')) return host;
  final ip = InternetAddress.tryParse(host);
  if (ip == null || ip.type != InternetAddressType.IPv6) return null;
  // InternetAddress.address is platform text (Windows does not compress
  // zeros), so the RFC 5952 form is built here to match the server.
  return vpsCompressIPv6(ip.rawAddress);
}

/// RFC 5952 text for a 16-byte IPv6 address: lower-case hex, no leading
/// zeros, and the longest run (two or more) of zero groups shortened to "::".
String vpsCompressIPv6(List<int> raw) {
  final groups = [for (var i = 0; i < 16; i += 2) (raw[i] << 8) | raw[i + 1]];
  var bestStart = -1, bestLen = 0;
  for (var i = 0; i < 8;) {
    if (groups[i] != 0) {
      i++;
      continue;
    }
    var j = i;
    while (j < 8 && groups[j] == 0) {
      j++;
    }
    if (j - i > bestLen) {
      bestStart = i;
      bestLen = j - i;
    }
    i = j;
  }
  String hex(Iterable<int> g) => g.map((v) => v.toRadixString(16)).join(':');
  if (bestLen < 2) return hex(groups);
  return '${hex(groups.take(bestStart))}::'
      '${hex(groups.skip(bestStart + bestLen))}';
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
      ? vpsLocalProxyAuth(
          ref.watch(networkSettingProvider.select((s) => s.authentication)),
        )
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
      // The smart line lists one group per server; their lines are what
      // gets watched.
      final candidates = smart != null
          ? [
              smart,
              for (final g in groups)
                if (smart.all.any((p) => p.name == g.name)) g,
            ]
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
          final host = vpsLineReportHost(def);
          if (kind == null || host == null) continue;
          lines.add(
            VpsWatchedLine(
              name: proxy.name,
              kind: kind,
              host: host,
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
      proxyPort: ref.read(patchClashConfigProvider).mixedPort,
      proxyAuth: vpsLocalProxyAuth(
        ref.read(networkSettingProvider).authentication,
      ),
      scope: scope,
      pinnedSha256: pinnedSha256,
    ),
  );
  ref.onDispose(() {
    watch.dispose();
    scope.close();
  });
  // A wake or a new network can leave a line dead; look before the timer does.
  ref.listen(networkResetsProvider, (_, _) => unawaited(watch.checkNow()));
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
final _reservedReleaseName = RegExp(
  r'^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
  caseSensitive: false,
);
const _maxReleaseBytes = 512 * 1024 * 1024;
const _releaseTransferTimeout = Duration(minutes: 8);
final _activeReleaseDownloads = <String>{};

/// Download a release only over verified or explicitly pinned HTTPS, and keep
/// it only when `<url>.sig` is the release key's signature for it (see
/// update_signing.dart) and, given [currentVersion], its file name carries a
/// newer version. Otherwise [VpsUpdateRejected] and nothing is kept.
/// Staging is isolated, and overlapping downloads to the same destination
/// are rejected even when callers spell that destination differently.
/// Direct first, then through our own proxy at [proxyPort] (a panel reachable
/// only over the VPN). One lock covers both attempts; a bad link or name, a
/// rejected signature, a disk error or a program error is final.
Future<File> vpsDownloadRelease(
  Uri url,
  Directory dir, {
  Set<String> pinnedSha256 = const {},
  String? currentVersion,
  String publicKeyHex = vpsUpdatePublicKeyHex,
  void Function(int received, int total)? onProgress,
  int? proxyPort,
  String? proxyAuth,
}) async {
  if (!url.isScheme('https')) {
    throw const HttpException('Release link is not HTTPS');
  }
  final name = url.pathSegments.isEmpty ? '' : url.pathSegments.last;
  if (!_releaseFileName.hasMatch(name) ||
      name.endsWith('.') ||
      _reservedReleaseName.hasMatch(name)) {
    throw const HttpException('Unexpected release file name');
  }
  if (currentVersion != null) {
    // The signature covers the file name, so its version cannot be faked: an
    // older signed installer cannot be passed off as an update.
    final version = vpsUpdateFileVersion(name);
    if (version == null || !vpsVersionNewer(version, currentVersion)) {
      throw const VpsUpdateRejected('notNewer');
    }
  }

  // Symlinked parents and case aliases must map to one logical lock.
  final canonicalDirectory = await dir.resolveSymbolicLinks();
  final targetPath = File(
    '$canonicalDirectory${Platform.pathSeparator}$name',
  ).absolute.path;
  final targetKey = (Platform.isWindows || Platform.isMacOS)
      ? targetPath.toLowerCase()
      : targetPath;
  if (!_activeReleaseDownloads.add(targetKey)) {
    throw const HttpException('Release download already in progress');
  }
  try {
    for (final port in [null, ?proxyPort]) {
      try {
        return await _downloadReleaseVia(
          url,
          dir,
          name,
          port: port,
          proxyAuth: port == null ? null : proxyAuth,
          pinnedSha256: pinnedSha256,
          publicKeyHex: publicKeyHex,
          onProgress: onProgress,
        );
      } on VpsUpdateRejected {
        rethrow;
      } on FileSystemException {
        rethrow;
      } on Exception {
        if (port != null || proxyPort == null) rethrow;
      }
    }
    throw StateError('unreachable');
  } finally {
    _activeReleaseDownloads.remove(targetKey);
  }
}

/// One transfer of the already checked [name], direct or through [port].
Future<File> _downloadReleaseVia(
  Uri url,
  Directory dir,
  String name, {
  required int? port,
  required String? proxyAuth,
  required Set<String> pinnedSha256,
  required String publicKeyHex,
  void Function(int received, int total)? onProgress,
}) async {
  final out = File('${dir.path}${Platform.pathSeparator}$name');
  HttpClient? client;
  Directory? staging;
  try {
    client = _client(
      proxyPort: port,
      proxyAuth: proxyAuth,
      base: url,
      pinnedSha256: pinnedSha256,
    );
    // A private temp directory prevents predictable .part path collisions and
    // prevents following a pre-existing symlink to an unrelated user file.
    staging = await dir.createTemp('.vps2vpn-release-');
    final part = File('${staging.path}${Platform.pathSeparator}$name.part');
    final req = await client.getUrl(url).timeout(const Duration(seconds: 15));
    req.followRedirects = false;
    final res = await req.close().timeout(const Duration(seconds: 15));
    if (res.statusCode != HttpStatus.ok) {
      // Do not drain an unbounded 4xx/5xx response: close the client below.
      throw HttpException('Download failed (HTTP ${res.statusCode})');
    }

    final total = res.contentLength > 0 ? res.contentLength : 0;
    final output = await part.open(mode: FileMode.write);
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    final elapsed = Stopwatch()..start();
    var size = 0;
    try {
      await for (final chunk in res.timeout(const Duration(seconds: 60))) {
        size += chunk.length;
        if (size > _maxReleaseBytes) {
          throw const HttpException('Release file too large');
        }
        if (elapsed.elapsed > _releaseTransferTimeout) {
          throw const HttpException('Release download took too long');
        }
        // Await disk I/O: IOSink.add queues unbounded pending writes on slow disks.
        await output.writeFrom(chunk);
        hasher.add(chunk);
        onProgress?.call(size, total);
      }
    } finally {
      await output.close();
    }
    hasher.close();
    if (size == 0) {
      throw const HttpException('Release file was empty');
    }
    // A connection that dropped part way is a failed transfer to try again,
    // not a file whose signature is wrong.
    if (total > 0 && size != total) {
      throw const HttpException('Release download was cut short');
    }
    final signature = await _fetchSignature(client, url, name);
    if (signature == null) throw const VpsUpdateRejected('unsigned');
    if (!vpsVerifyUpdate(
      fileName: name,
      sha256Hex: digest.value.toString(),
      size: size,
      signatureText: signature,
      publicKeyHex: publicKeyHex,
    )) {
      throw const VpsUpdateRejected('badSignature');
    }
    // Never delete a previously verified release before this rename. On
    // Windows an antivirus scan of the installer it replaces can hold that
    // file for a moment.
    for (var attempt = 1; ; attempt++) {
      try {
        return await part.rename(out.path);
      } on FileSystemException {
        if (!Platform.isWindows || attempt >= 5) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
      }
    }
  } finally {
    client?.close(force: true);
    if (staging != null) {
      await staging.delete(recursive: true);
    }
  }
}

/// `<installer>.sig` next to the download, or null when there is none.
Future<String?> _fetchSignature(HttpClient client, Uri url, String name) async {
  final sigUrl = url.replace(
    pathSegments: [
      ...url.pathSegments.take(url.pathSegments.length - 1),
      '$name.sig',
    ],
  );
  final req = await client.getUrl(sigUrl).timeout(const Duration(seconds: 15));
  req.followRedirects = false;
  final res = await req.close().timeout(const Duration(seconds: 15));
  if (res.statusCode != HttpStatus.ok) {
    if (res.statusCode == HttpStatus.notFound) return null;
    throw HttpException('Signature download failed (HTTP ${res.statusCode})');
  }
  return _readBoundedUtf8(
    res,
    maxBytes: 4096,
  ).timeout(const Duration(seconds: 15));
}
