// vps2vpn "Check", the exit part: the IPv6 exit, the DNS server, this
// computer's time zone and language against the exit country, and a
// one-line verdict that names only what is wrong.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/ip_quality.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/home.dart' show countryName;
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Hosts with only an AAAA record, so an answer means IPv6 got through.
final Map<String, IpInfo Function(Map<String, dynamic>)> _ipv6Sources = {
  'https://api-ipv6.ip.sb/geoip': IpInfo.fromIpSbJson,
  'https://v6.ident.me/json': IpInfo.fromIdentMeJson,
};

@visibleForTesting
IpInfo? parseIpv6Answer(OutboundIpResult result) {
  final parse = _ipv6Sources[result.url];
  if (result.error != null || parse == null) return null;
  try {
    final info = parse(jsonDecode(result.body) as Map<String, dynamic>);
    return info.ip.contains(':') ? info : null;
  } catch (_) {
    return null;
  }
}

/// The resolver ip-api.com saw for a one-off name: `dns.geo` reads like
/// "China - Chinanet".
@visibleForTesting
({String ip, String geo})? parseEdnsAnswer(String body) {
  try {
    final dns = (jsonDecode(body) as Map<String, dynamic>)['dns'];
    if (dns is! Map) return null;
    final ip = dns['ip'];
    final geo = dns['geo'];
    if (ip is! String || geo is! String) return null;
    return (ip: ip, geo: geo);
  } catch (_) {
    return null;
  }
}

class VpsExitFacts {
  const VpsExitFacts({this.ipv6Exit, this.ipv6Local, this.dns});

  /// IPv6 as the rules send it, and straight out of this computer.
  final IpInfo? ipv6Exit;
  final IpInfo? ipv6Local;
  final ({String ip, String geo})? dns;
}

Future<OutboundIpResult?> vpsAskCore(
  CoreController core,
  String proxyName,
  List<String> urls,
) async {
  try {
    return await core.outboundIp(
      OutboundIpParams(proxyName: proxyName, urls: urls, timeout: 6000),
    );
  } catch (_) {
    return null;
  }
}

/// Asked when Check opens or is asked again, kept five minutes after.
final vpsExitFactsProvider = FutureProvider.autoDispose<VpsExitFacts>((
  ref,
) async {
  final link = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 5), link.close);
  ref.onDispose(timer.cancel);
  final core = ref.read(coreHandlerProvider);
  final ipv6 = _ipv6Sources.keys.toList();
  final token = List.generate(
    12,
    (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[Random.secure().nextInt(36)],
  ).join();
  final answers = await Future.wait([
    vpsAskCore(core, routedOutbound, ipv6),
    vpsAskCore(core, directOutbound, ipv6),
    vpsAskCore(core, routedOutbound, ['http://$token.edns.ip-api.com/json']),
  ]);
  final dns = answers[2];
  return VpsExitFacts(
    ipv6Exit: answers[0] == null ? null : parseIpv6Answer(answers[0]!),
    ipv6Local: answers[1] == null ? null : parseIpv6Answer(answers[1]!),
    dns: dns == null || dns.error != null ? null : parseEdnsAnswer(dns.body),
  );
});

/// UTC offsets, in hours, a clock in each country can show (summer time
/// included). Countries not listed get no verdict.
const _offsets = <String, (double, double)>{
  'US': (-10, -4),
  'CA': (-8, -2.5),
  'MX': (-8, -5),
  'BR': (-5, -2),
  'AR': (-3, -3),
  'CL': (-4, -3),
  'GB': (0, 1),
  'IE': (0, 1),
  'PT': (-1, 1),
  'ES': (0, 2),
  'FR': (1, 2),
  'DE': (1, 2),
  'NL': (1, 2),
  'BE': (1, 2),
  'LU': (1, 2),
  'IT': (1, 2),
  'CH': (1, 2),
  'AT': (1, 2),
  'SE': (1, 2),
  'NO': (1, 2),
  'DK': (1, 2),
  'PL': (1, 2),
  'CZ': (1, 2),
  'HU': (1, 2),
  'FI': (2, 3),
  'EE': (2, 3),
  'LV': (2, 3),
  'LT': (2, 3),
  'UA': (2, 3),
  'RO': (2, 3),
  'BG': (2, 3),
  'GR': (2, 3),
  'IL': (2, 3),
  'TR': (3, 3),
  'RU': (2, 12),
  'AE': (4, 4),
  'SA': (3, 3),
  'IN': (5.5, 5.5),
  'TH': (7, 7),
  'VN': (7, 7),
  'ID': (7, 9),
  'MY': (8, 8),
  'SG': (8, 8),
  'PH': (8, 8),
  'HK': (8, 8),
  'MO': (8, 8),
  'TW': (8, 8),
  'CN': (8, 8),
  'JP': (9, 9),
  'KR': (9, 9),
  'AU': (8, 11),
  'NZ': (12, 13),
  'ZA': (2, 2),
};

/// Whether a clock [offset] from UTC fits [country]; null when unknown.
bool? vpsTimeZoneFits(String country, Duration offset) {
  final range = _offsets[country.toUpperCase()];
  if (range == null) return null;
  final hours = offset.inMinutes / 60;
  return hours >= range.$1 && hours <= range.$2;
}

const _languages = <String, Set<String>>{
  'US': {'en'},
  'GB': {'en'},
  'IE': {'en'},
  'CA': {'en', 'fr'},
  'AU': {'en'},
  'NZ': {'en'},
  'SG': {'en', 'zh', 'ms'},
  'IN': {'en', 'hi'},
  'JP': {'ja'},
  'KR': {'ko'},
  'TW': {'zh'},
  'HK': {'zh', 'en'},
  'MO': {'zh'},
  'CN': {'zh'},
  'MY': {'ms', 'en', 'zh'},
  'DE': {'de'},
  'AT': {'de'},
  'CH': {'de', 'fr', 'it'},
  'FR': {'fr'},
  'NL': {'nl'},
  'ES': {'es'},
  'IT': {'it'},
  'RU': {'ru'},
  'BR': {'pt'},
  'PT': {'pt'},
};

/// Whether a system language [localeName] (`zh_CN`, `en-US`) is spoken in
/// [country]; null when unknown.
bool? vpsLanguageFits(String country, String localeName) {
  final spoken = _languages[country.toUpperCase()];
  if (spoken == null) return null;
  final language = localeName.split(RegExp('[-_]')).first.toLowerCase();
  return spoken.contains(language);
}

/// The last part of an address hidden, for text a user pastes elsewhere.
String vpsMaskLast(String ip) {
  final sep = ip.contains(':') ? ':' : '.';
  final parts = ip.split(sep);
  if (parts.length < 2) return '*';
  return [...parts.take(parts.length - 1), '*'].join(sep);
}

enum VpsFindingLevel { good, warn, bad, none }

class VpsFinding {
  const VpsFinding(this.title, this.value, this.level, {this.problem});

  final String title;
  final String value;
  final VpsFindingLevel level;

  /// What the verdict line says when this is wrong.
  final String? problem;
}

/// Each row of the exit report, in order; [exit] is the IPv4 exit.
List<VpsFinding> vpsExitFindings(
  BuildContext context, {
  required IpInfo? exit,
  required IpQuality? quality,
  required VpsExitFacts? facts,
  required Duration offset,
  required String localeName,
}) {
  final country = exit?.countryCode.toUpperCase();
  final where = country == null ? null : countryName(context, country);
  final rows = <VpsFinding>[];
  if (quality != null) {
    final flagged = quality.isProxy || quality.isVpn;
    final risky = quality.isTor || quality.isAbuser;
    final type = switch (quality.type) {
      IpType.hosting => tr(context, '机房 IP', 'Datacenter IP'),
      IpType.residential => tr(context, '家宽 IP', 'Home broadband IP'),
      IpType.mobile => tr(context, '手机网络 IP', 'Mobile network IP'),
      IpType.business => tr(context, '企业网络 IP', 'Business network IP'),
    };
    rows.add(
      VpsFinding(
        tr(context, 'IP 类型', 'IP type'),
        [
          type,
          if (flagged) tr(context, '被标记为代理', 'flagged as a proxy'),
          if (risky) tr(context, '有滥用记录', 'abuse on record'),
        ].join(tr(context, '，', ', ')),
        risky
            ? VpsFindingLevel.bad
            : flagged || quality.type == IpType.hosting
            ? VpsFindingLevel.warn
            : VpsFindingLevel.good,
        problem: risky
            ? tr(context, '出口 IP 有滥用记录', 'the exit IP has abuse on record')
            : flagged
            ? tr(context, '出口 IP 被标记为代理', 'the exit IP is flagged as a proxy')
            : null,
      ),
    );
  }
  if (facts != null) {
    final v6 = facts.ipv6Exit;
    final local = facts.ipv6Local;
    final leaks = v6 != null && local != null && v6.ip == local.ip;
    final elsewhere =
        !leaks &&
        v6 != null &&
        country != null &&
        v6.countryCode.toUpperCase() != country;
    rows.add(
      VpsFinding(
        tr(context, 'IPv6 出口', 'IPv6 exit'),
        leaks
            ? tr(
                context,
                '直连出去了，没走节点',
                'goes out directly, not through the node',
              )
            : v6 != null
            ? countryName(context, v6.countryCode)
            : local != null
            ? tr(
                context,
                '节点不走 IPv6，本机 IPv6 未外泄',
                'node has no IPv6; yours stays home',
              )
            : tr(context, '本机没有 IPv6', 'no IPv6 here'),
        leaks
            ? VpsFindingLevel.bad
            : elsewhere
            ? VpsFindingLevel.warn
            : VpsFindingLevel.good,
        problem: leaks
            ? tr(context, 'IPv6 直连', 'IPv6 goes out directly')
            : elsewhere
            ? tr(
                context,
                'IPv6 出口和 IPv4 不在同一国家',
                'IPv6 leaves from another country',
              )
            : null,
      ),
    );
    final dns = facts.dns;
    if (dns != null) {
      final home = dns.geo.toLowerCase().startsWith('china') && country != 'CN';
      rows.add(
        VpsFinding(
          'DNS',
          dns.geo,
          home ? VpsFindingLevel.warn : VpsFindingLevel.good,
          problem: home
              ? tr(context, 'DNS 由国内服务器解析', 'DNS answered from China')
              : null,
        ),
      );
    }
  }
  final hours = offset.inMinutes / 60;
  final utc =
      'UTC${hours >= 0 ? '+' : ''}${hours == hours.roundToDouble() ? hours.round() : hours}';
  final zoneFits = country == null ? null : vpsTimeZoneFits(country, offset);
  rows.add(
    VpsFinding(
      tr(context, '系统时区', 'Time zone'),
      utc,
      switch (zoneFits) {
        null => VpsFindingLevel.none,
        true => VpsFindingLevel.good,
        false => VpsFindingLevel.bad,
      },
      problem: zoneFits == false
          ? tr(context, '时区和出口国家（$where）不一致', 'time zone does not match $where')
          : null,
    ),
  );
  final languageFits = country == null
      ? null
      : vpsLanguageFits(country, localeName);
  rows.add(
    VpsFinding(
      tr(context, '系统语言', 'System language'),
      localeName,
      switch (languageFits) {
        null => VpsFindingLevel.none,
        true => VpsFindingLevel.good,
        false => VpsFindingLevel.warn,
      },
      problem: languageFits == false
          ? tr(
              context,
              '系统语言和出口国家不一致',
              'system language differs from the exit country',
            )
          : null,
    ),
  );
  return rows;
}

/// The verdict line: "一切正常" or "2 项有问题：…".
String vpsExitVerdict(BuildContext context, List<VpsFinding> rows) {
  final problems = [
    for (final r in rows)
      if (r.problem != null) r.problem!,
  ];
  if (problems.isEmpty) return tr(context, '一切正常', 'All good');
  return tr(
    context,
    '${problems.length} 项有问题：${problems.join('；')}',
    '${problems.length} to look at: ${problems.join('; ')}',
  );
}

/// The report as text, every address with its last part hidden.
String vpsExitReportText(
  BuildContext context, {
  required IpInfo? exit,
  required IpInfo? ipv6Exit,
  required List<VpsFinding> rows,
}) => [
  vpsExitVerdict(context, rows),
  if (exit != null)
    '${tr(context, '出口', 'Exit')}: ${countryName(context, exit.countryCode)} ${vpsMaskLast(exit.ip)}',
  if (ipv6Exit != null) 'IPv6: ${vpsMaskLast(ipv6Exit.ip)}',
  for (final r in rows) '${r.title}: ${r.value}',
].join('\n');

/// The verdict at the top of Check and the rows under it.
class VpsExitReport extends ConsumerWidget {
  const VpsExitReport({super.key, required this.exit});

  final IpInfo? exit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final facts = ref.watch(vpsExitFactsProvider);
    final ip = exit?.ip;
    final quality = ip == null ? null : ref.watch(ipQualityProvider(ip)).value;
    final rows = vpsExitFindings(
      context,
      exit: exit,
      quality: quality,
      facts: facts.value,
      offset: DateTime.now().timeZoneOffset,
      localeName: Platform.localeName,
    );
    return VpsFindingCard(
      rows: rows,
      settled: exit != null && !facts.isLoading,
      copyText: () => vpsExitReportText(
        context,
        exit: exit,
        ipv6Exit: facts.value?.ipv6Exit,
        rows: rows,
      ),
    );
  }
}

/// A verdict line over one row per finding, with a copy button.
class VpsFindingCard extends StatelessWidget {
  const VpsFindingCard({
    super.key,
    required this.rows,
    required this.settled,
    required this.copyText,
  });

  final List<VpsFinding> rows;
  final bool settled;
  final String Function() copyText;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final bad = rows.any((r) => r.level == VpsFindingLevel.bad);
    final warn = rows.any((r) => r.level == VpsFindingLevel.warn);
    return VpsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: VpsBreathe(
                  active: !settled,
                  child: Text(
                    settled
                        ? vpsExitVerdict(context, rows)
                        : tr(context, '体检中…', 'Checking…'),
                    style: vpsText(
                      p,
                      size: 15,
                      weight: FontWeight.w600,
                      color: !settled
                          ? p.soft
                          : bad
                          ? p.bad
                          : warn
                          ? p.warn
                          : p.good,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              VpsButton(
                label: tr(context, '复制结果', 'Copy'),
                onTap: !settled
                    ? null
                    : () => Clipboard.setData(ClipboardData(text: copyText())),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final (i, r) in rows.indexed) ...[
            if (i > 0) Container(height: 1, color: p.line),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      r.title,
                      style: vpsText(p, size: 14, weight: FontWeight.w500),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: VpsChip(
                      label: r.value,
                      color: switch (r.level) {
                        VpsFindingLevel.good => p.good,
                        VpsFindingLevel.warn => p.warn,
                        VpsFindingLevel.bad => p.bad,
                        VpsFindingLevel.none => p.soft,
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
