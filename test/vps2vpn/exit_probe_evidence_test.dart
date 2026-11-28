import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/vps2vpn/exit_check.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' show ThemeMode;

import '../helpers/test_app.dart';

const _exit = IpInfo(ip: '198.51.100.1', countryCode: 'JP');
const _routed = IpInfo(ip: '2001:db8::1', countryCode: 'JP');
const _local = IpInfo(ip: '2001:db8::2', countryCode: 'JP');
const _dns = (ip: '198.51.100.53', geo: 'Japan - Example');

Future<BuildContext> _context(WidgetTester tester) async {
  late BuildContext result;
  await tester.pumpWidget(
    TestApp(
      includeNavigatorKey: false,
      locale: const Locale('en'),
      child: Builder(
        builder: (context) {
          result = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return result;
}

List<VpsFinding> _findings(BuildContext context, VpsExitFacts facts) =>
    vpsExitFindings(
      context,
      exit: _exit,
      quality: null,
      facts: facts,
      offset: const Duration(hours: 9),
      localeName: 'ja_JP',
    );

void main() {
  test('malformed addresses cannot become successful probe evidence', () {
    expect(parseEdnsAnswer('{"dns":{"ip":"","geo":""}}'), isNull);
    expect(parseEdnsAnswer('{"dns":{"ip":"invalid","geo":"Japan"}}'), isNull);
  });

  testWidgets('failed IPv6 and DNS probes leave the report incomplete', (
    tester,
  ) async {
    final context = await _context(tester);
    final rows = _findings(context, const VpsExitFacts());
    final ipv6 = rows.singleWhere((row) => row.title == 'IPv6 exit');
    final dns = rows.singleWhere((row) => row.title == 'DNS');
    expect(ipv6.level, VpsFindingLevel.none);
    expect(dns.level, VpsFindingLevel.none);
    expect(ipv6.value, 'Could not confirm');
    expect(vpsExitHeading(context, rows), 'Checks incomplete');
    final report = vpsExitReportText(
      context,
      exit: _exit,
      ipv6Exit: null,
      rows: rows,
    );
    expect(report, contains('2 checks incomplete'));
    expect(report, isNot(contains('All good')));
    expect(report, isNot(contains('No IPv6')));
  });

  testWidgets('one successful IPv6 direction does not prove no leak', (
    tester,
  ) async {
    final context = await _context(tester);
    for (final facts in const [
      VpsExitFacts(ipv6Exit: _routed, dns: _dns),
      VpsExitFacts(ipv6Local: _local, dns: _dns),
    ]) {
      final rows = _findings(context, facts);
      expect(
        rows.singleWhere((row) => row.title == 'IPv6 exit').level,
        VpsFindingLevel.none,
      );
      expect(vpsExitHeading(context, rows), 'Checks incomplete');
      expect(vpsExitVerdict(context, rows), contains('1 check incomplete'));
    }
  });

  testWidgets('a DNS failure remains visible after a complete IPv6 check', (
    tester,
  ) async {
    final context = await _context(tester);
    final rows = _findings(
      context,
      const VpsExitFacts(ipv6Exit: _routed, ipv6Local: _local),
    );
    expect(
      rows.singleWhere((row) => row.title == 'DNS').level,
      VpsFindingLevel.none,
    );
    expect(vpsExitHeading(context, rows), 'Checks incomplete');
  });

  testWidgets('complete evidence preserves good and leaked IPv6 verdicts', (
    tester,
  ) async {
    final context = await _context(tester);
    final good = _findings(
      context,
      const VpsExitFacts(ipv6Exit: _routed, ipv6Local: _local, dns: _dns),
    );
    expect(vpsExitHeading(context, good), 'All good');
    expect(vpsExitVerdict(context, good), 'All good');
    final leaked = _findings(
      context,
      const VpsExitFacts(ipv6Exit: _local, ipv6Local: _local),
    );
    expect(leaked.first.level, VpsFindingLevel.bad);
    expect(vpsExitHeading(context, leaked), '1 issue · 1 incomplete');
    expect(vpsExitVerdict(context, leaked), contains('IPv6 goes out directly'));
    expect(vpsExitVerdict(context, leaked), contains('1 check incomplete'));
  });

  for (final mode in [ThemeMode.dark, ThemeMode.light]) {
    testWidgets('incomplete findings render at narrow width in $mode', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        TestApp(
          includeNavigatorKey: false,
          locale: const Locale('en'),
          themeMode: mode,
          child: Builder(
            builder: (context) {
              final rows = _findings(context, const VpsExitFacts());
              return MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.5)),
                child: SingleChildScrollView(
                  child: VpsFindingCard(
                    rows: rows,
                    settled: true,
                    copyText: () => vpsExitVerdict(context, rows),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Checks incomplete'), findsOneWidget);
      expect(find.text('2 checks incomplete; check again'), findsOneWidget);
      expect(find.text('Could not confirm'), findsNWidgets(2));
      expect(find.text('Copy results'), findsOneWidget);
      expect(find.text('All good'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
