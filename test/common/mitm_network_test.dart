import 'package:fl_clash/common/mitm_network.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('equivalent domain maps remain interchangeable as collection keys', () {
    const first = MitmNetwork(
      nameserverPolicy: {
        'one.example': ['192.0.2.1'],
        'two.example': ['192.0.2.2'],
      },
      hosts: {
        'one.example': ['192.0.2.10'],
        'two.example': ['192.0.2.20'],
      },
    );
    for (final reversed in [
      MitmNetwork(
        nameserverPolicy: Map.fromEntries(
          first.nameserverPolicy.entries.toList().reversed,
        ),
        hosts: first.hosts,
      ),
      MitmNetwork(
        nameserverPolicy: first.nameserverPolicy,
        hosts: Map.fromEntries(first.hosts.entries.toList().reversed),
      ),
    ]) {
      expect(reversed, first);
      expect({first, reversed}, hasLength(1));
      expect({first: 'cached'}[reversed], 'cached');
    }
  });

  test('list edits replace, go first or go last, in module order', () {
    const profile = ['1.1.1.1'];
    expect(const MitmListEdit(replace: true, before: ['a']).applyTo(profile), [
      'a',
    ]);
    expect(const MitmListEdit(before: ['a']).applyTo(profile), [
      'a',
      '1.1.1.1',
    ]);
    expect(
      const MitmListEdit(
        before: ['a'],
      ).then(const MitmListEdit(after: ['b'])).applyTo(profile),
      ['a', '1.1.1.1', 'b'],
    );
    expect(
      const MitmListEdit(after: ['a'])
          .then(const MitmListEdit(replace: true, before: ['b']))
          .then(const MitmListEdit(before: ['c']))
          .applyTo(profile),
      ['c', 'b'],
    );
  });

  test('later modules win a per-domain entry and fold their lists', () {
    final merged = MitmNetwork.merge(const [
      MitmNetwork(
        nameserver: MitmListEdit(replace: true, before: ['a']),
        hosts: {
          'x.test': ['1.1.1.1'],
        },
        routeAddress: ['10.0.0.0/8'],
        bypassDomain: MitmListEdit(after: ['*.local']),
      ),
      MitmNetwork(
        nameserver: MitmListEdit(after: ['b']),
        hosts: {
          'x.test': ['2.2.2.2'],
        },
        routeAddress: ['10.0.0.0/8', '172.16.0.0/12'],
        bypassDomain: MitmListEdit(after: ['captive.test']),
      ),
    ]);
    expect(merged.nameserver?.applyTo(const ['p']), ['a', 'b']);
    expect(merged.hosts, {
      'x.test': ['2.2.2.2'],
    });
    expect(merged.routeAddress, ['10.0.0.0/8', '172.16.0.0/12']);
    expect(merged.bypassDomain?.applyTo(const ['localhost']), [
      'localhost',
      '*.local',
      'captive.test',
    ]);
  });

  test('DNS changes go over what the profile and the user set', () {
    final dns = <String, dynamic>{
      'nameserver': ['1.1.1.1'],
      'fake-ip-filter': ['*.lan'],
      'nameserver-policy': {'a.test': '8.8.8.8', 'b.test': '8.8.8.8'},
    };
    const MitmNetwork(
      nameserver: MitmListEdit(replace: true, before: ['9.9.9.9']),
      defaultNameserver: MitmListEdit(replace: true, before: ['223.5.5.5']),
      fakeIpFilter: MitmListEdit(after: ['*.lan', 'time.test']),
      nameserverPolicy: {
        'b.test': ['system://'],
      },
    ).applyToDns(dns);
    expect(dns, {
      'nameserver': ['9.9.9.9'],
      'default-nameserver': ['223.5.5.5'],
      'fake-ip-filter': ['*.lan', 'time.test'],
      'nameserver-policy': {
        'a.test': '8.8.8.8',
        'b.test': ['system://'],
      },
    });
  });

  test('routes reach the TUN, and included ones only a list it names', () {
    const network = MitmNetwork(
      routeAddress: ['10.0.0.0/8'],
      routeExcludeAddress: MitmListEdit(after: ['192.168.0.0/16']),
    );
    final open = <String, dynamic>{};
    network.applyToTun(open);
    expect(open, {
      'route-exclude-address': ['192.168.0.0/16'],
    });
    final narrow = <String, dynamic>{
      'route-address': ['172.16.0.0/12'],
      'route-exclude-address': ['1.1.1.1/32'],
    };
    const MitmNetwork(
      routeAddress: ['10.0.0.0/8'],
      routeExcludeAddress: MitmListEdit(replace: true, before: ['::1/128']),
    ).applyToTun(narrow);
    expect(narrow, {
      'route-address': ['172.16.0.0/12', '10.0.0.0/8'],
      'route-exclude-address': ['::1/128'],
    });
  });

  test('a change replaces whole lists and single domains only', () {
    const later = MitmNetwork(
      nameserver: MitmListEdit(replace: true, before: ['b']),
      defaultNameserver: MitmListEdit(after: ['c']),
      hosts: {
        'x.test': ['2.2.2.2'],
      },
    );
    final changes = const MitmNetwork(
      nameserver: MitmListEdit(after: ['a']),
      defaultNameserver: MitmListEdit(replace: true, before: ['a']),
      hosts: {
        'x.test': ['1.1.1.1'],
        'y.test': ['1.1.1.1'],
      },
    ).changes;
    expect(
      [for (final change in changes) change.replacedBy(later)],
      [true, false, true, false],
    );
    expect(
      [for (final change in changes) change.replaces],
      [false, true, true, true],
    );
  });

  test('plain DNS accepts IPv4 ports and bracketed IPv6 ports', () {
    for (final server in [
      '8.8.8.8:53',
      '1.1.1.1:853',
      '127.0.0.1:5353',
      '2001:db8::1',
      '[2001:db8::1]',
      '[2001:db8::1]:853',
    ]) {
      expect(mitmDnsServer(server), server, reason: server);
      expect(isMitmPlainDnsServer(server), isTrue, reason: server);
    }
    expect(isMitmPlainDnsServer('system://'), isTrue);
    expect(isMitmPlainDnsServer('tls://dns.example'), isFalse);
  });

  test('plain DNS refuses malformed addresses and invalid ports', () {
    for (final server in [
      '8.8.8.8:0',
      '8.8.8.8:65536',
      '8.8.8.8:999999',
      '8.8.8.8:-1',
      '8.8.8.8:abc',
      '8.8.8.8::53',
      '999.999.999.999:53',
      '[2001:db8::1]:0',
      '[2001:db8::1]:65536',
      '[2001:db8::1]junk',
      '[1.1.1.1]:53',
      '1.1.1.1:53:53',
      'dns.google:53',
      'dns.google',
    ]) {
      expect(mitmDnsServer(server), isNull, reason: server);
      expect(isMitmPlainDnsServer(server), isFalse, reason: server);
    }
  });

  test('DNS servers and routes read as the Core takes them', () {
    expect(mitmDnsServer('system'), 'system://');
    expect(mitmDnsServer('223.5.5.5'), '223.5.5.5');
    expect(mitmDnsServer('[2400:3200::1]:53'), '[2400:3200::1]:53');
    expect(
      mitmDnsServer('h3://dns.alidns.com/dns-query'),
      'https://dns.alidns.com/dns-query#h3=true',
    );
    expect(mitmDnsServer('quic://dns.test'), 'quic://dns.test');
    expect(mitmDnsServer('dns.test'), isNull);
    expect(mitmRoute('10.0.0.0/8'), '10.0.0.0/8');
    expect(mitmRoute('1.1.1.1'), '1.1.1.1/32');
    expect(mitmRoute('2001:db8::1'), '2001:db8::1/128');
    expect(mitmRoute('lan'), isNull);
  });
}
