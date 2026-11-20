import 'package:fl_clash/vps2vpn/line_watch.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('line reporting accepts canonical IPv6 but rejects host:port', () {
    expect(
      vpsLineReportHost({'server': '2001:4860:4860::8888'}),
      '2001:4860:4860::8888',
    );
    expect(
      vpsLineReportHost({'server': '[2001:4860:4860::8888]'}),
      '2001:4860:4860::8888',
    );
    expect(
      vpsLineReportHost({'server': '2001:0db8:0:0:0:0:0:1'}),
      '2001:db8::1',
    );
    expect(vpsLineReportHost({'server': 'proxy.example'}), 'proxy.example');
    expect(vpsLineReportHost({'server': '192.0.2.8'}), '192.0.2.8');
    expect(vpsLineReportHost({'server': 'proxy.example:443'}), isNull);
    expect(vpsLineReportHost({'server': '[2001:db8::1]:443'}), isNull);
    expect(vpsLineReportHost({'server': 'fe80::1%lo0'}), isNull);
    expect(vpsLineReportHost({'server': ''}), isNull);
    expect(vpsLineReportHost({'server': 42}), isNull);
  });

  test('an IPv6-only line reports down and recovery after real scans', () async {
    final host = vpsLineReportHost({'server': '[2001:4860:4860::8888]'})!;
    final line = VpsWatchedLine(
      name: 'hy2-ipv6',
      kind: 'hy2',
      host: host,
      testUrl: 'https://probe.invalid',
    );
    var healthy = false;
    final reports = <(String, bool)>[];
    final watch = VpsLineWatch(
      lines: () async => [line],
      probe: (_) async => healthy,
      report: (node, ok) async {
        reports.add((node.host, ok));
        return true;
      },
    );
    addTearDown(watch.dispose);

    await watch.checkNow();
    await watch.checkNow();
    expect(reports, isEmpty);
    await watch.checkNow();
    expect(reports, [(host, false)]);

    healthy = true;
    await watch.checkNow();
    expect(reports, [(host, false), (host, true)]);
  });
}
