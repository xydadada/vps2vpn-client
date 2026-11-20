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
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      !(uri.isScheme('http') || uri.isScheme('https'))) {
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
    this.limited,
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
  final bool? limited;

  bool get isLimited => limited ?? quotaBytes > 0;
  final DateTime? expireAt;
  final VpsAiStatus? ai;
  final VpsClientRelease? client;

  double get used => _int(usedUp).toDouble() + _int(usedDown).toDouble();

  /// [isLimited] distinguishes an exhausted effective quota from unlimited.
  double get quotaBytes {
    final bytes = quotaGb * (1024 * 1024 * 1024);
    return bytes.isFinite && bytes > 0 ? bytes : 0;
  }

  static bool _positive(Object? value) =>
      value is num && value.isFinite && value > 0;

  static int _int(Object? value) {
    if (value is! num || !value.isFinite || value <= 0) return 0;
    const maxCount = 0x7fffffffffffffff;
    return value >= maxCount ? maxCount : value.toInt();
  }

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
      limited: _positive(json['quota_gb']) || _positive(quota),
      quotaGb: quota is num && quota.isFinite && quota > 0
          ? quota.toDouble()
          : 0,
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
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
  }
}

HttpClient _client(
  Uri url, {
  int? proxyPort,
  String? proxyCredentials,
  Set<String> certificatePins = const {},
}) {
  final c =
      HttpClient(
          context: certificatePins.isEmpty
              ? null
              : SecurityContext(withTrustedRoots: false),
        )
        ..badCertificateCallback = (certificate, host, port) {
          return host.toLowerCase() == url.host.toLowerCase() &&
              port == url.port &&
              certificatePins.contains(
                sha256.convert(certificate.der).toString(),
              );
        }
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
  VpsRequestScope? scope,
}) async {
  final client = _client(
    url,
    proxyPort: proxyPort,
    proxyCredentials: proxyCredentials,
    certificatePins: certificatePins,
  );
  try {
    scope?.attach(client);
    final req = body == null
        ? await client.getUrl(url)
        : await client.postUrl(url);
    req.followRedirects = false;
    if (body != null) {
      // A fixed length also supports panels predating chunked request handling.
      final bytes = utf8.encode(jsonEncode(body));
      req.headers
        ..set('X-V2V', '1')
        ..contentType = ContentType.json
        ..contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close().timeout(const Duration(seconds: 10));
    final text = await _responseText(res).timeout(const Duration(seconds: 10));
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
  String? proxyCredentials,
  Set<String> certificatePins = const {},
  VpsRequestScope? scope,
}) async {
  var result = const VpsMemberResult(problem: VpsPanelProblem.unreachable);
  for (final port in [null, ?proxyPort]) {
    if (scope?.closed == true) return null;
    try {
      final (code, text) = await _send(
        base.resolve('me'),
        proxyPort: port,
        proxyCredentials: proxyCredentials,
        certificatePins: certificatePins,
        scope: scope,
      );
      if (scope?.closed == true) return null;
      result = VpsMemberResult.fromResponse(base, code, text);
      if (result.member != null || result.linkChanged) return result;
    } catch (_) {}
  }
  return scope?.closed == true ? null : result;
}

/// Always direct: the line being reported is the one that is down.
Future<bool> reportLine(
  Uri base, {
  required String line,
  required bool ok,
  required String host,
  Set<String> certificatePins = const {},
  VpsRequestScope? scope,
}) async {
  try {
    final (code, _) = await _send(
      base.resolve('report'),
      body: {'line': line, 'ok': ok, 'host': host},
      certificatePins: certificatePins,
      scope: scope,
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
/// not a vps2vpn link.
final vpsMemberProvider = FutureProvider.autoDispose<VpsMemberResult?>((
  ref,
) async {
  final (profileId, url, _) = ref.watch(
    currentProfileProvider.select(
      (p) => (p?.id, p?.url ?? '', p?.lastUpdateDate),
    ),
  );
  final base = vpsApiBase(url);
  if (base == null) return null;
  if (!ref.watch(appVisibleProvider)) return null;
  final on = ref.watch(isStartProvider);
  final port = on
      ? ref.watch(patchClashConfigProvider.select((p) => p.mixedPort))
      : null;
  final credentials = ref.watch(
    networkSettingProvider.select((state) => state.authentication.credentials),
  );
  final scope = VpsRequestScope();
  Timer? timer;
  var listening = true;
  var finished = false;
  var interval = const Duration(minutes: 5);
  void schedule() {
    timer?.cancel();
    if (listening && finished && ref.mounted) {
      timer = Timer(interval, ref.invalidateSelf);
    }
  }

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
  final pins = await _profileCertificatePins(ref, profileId!, base);
  if (!ref.mounted) return null;
  final result = await fetchMember(
    base,
    proxyPort: port,
    proxyCredentials: credentials.firstOrNull,
    certificatePins: pins,
    scope: scope,
  );
  if (result?.problem == VpsPanelProblem.unreachable) {
    interval = const Duration(seconds: 30);
  }
  finished = true;
  schedule();
  return result;
});

final vpsLineWatchProvider = Provider.autoDispose<void>((ref) {
  if (ref.watch(safeModeProvider) ||
      Platform.environment.containsKey('FLUTTER_TEST') ||
      !ref.watch(isStartProvider) ||
      ref.watch(coreStatusProvider) != CoreStatus.connected) {
    return;
  }
  final (profileId, url, _) = ref.watch(
    currentProfileProvider.select(
      (p) => (p?.id, p?.url ?? '', p?.lastUpdateDate),
    ),
  );
  final base = vpsApiBase(url);
  if (base == null) return;
  final core = ref.watch(coreHandlerProvider);
  final scope = VpsRequestScope();
  final watch = VpsLineWatch(
    lines: () async {
      if (!await ref.read(setupActionProvider.notifier).inputsApplied() ||
          !ref.mounted) {
        return [];
      }
      final smart = ref
          .read(groupsProvider)
          .where((g) => g.name == vpsSmartGroupName)
          .firstOrNull;
      if (smart == null) return [];
      final lines = <VpsWatchedLine>[];
      for (final proxy in smart.all) {
        final def = await core.getProxyDefinition(proxy.name);
        if (!ref.mounted) return [];
        if (def == null) continue;
        final kind = vpsLineKind(def);
        final host = '${def['server'] ?? ''}';
        if (kind == null || host.isEmpty) continue;
        lines.add(
          VpsWatchedLine(
            name: proxy.name,
            kind: kind,
            host: host,
            testUrl: smart.testUrl ?? defaultTestUrl,
          ),
        );
      }
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
    report: (line, ok) async {
      final pins = await _profileCertificatePins(ref, profileId!, base);
      if (!ref.mounted) return false;
      return reportLine(
        base,
        line: line.kind,
        ok: ok,
        host: line.host,
        certificatePins: pins,
        scope: scope,
      );
    },
  );
  ref.onDispose(() {
    watch.dispose();
    scope.close();
  });
  watch.start();
});
