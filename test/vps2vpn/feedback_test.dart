import 'dart:convert';

import 'package:fl_clash/vps2vpn/feedback.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

VpsFeedbackAnswer _answer(VpsFeedbackOutcome outcome) =>
    (outcome: outcome, id: null, retryAfter: null);

void main() {
  group('masking', () {
    test('links, secrets, UUIDs and addresses are masked', () {
      final masked = vpsMaskSecrets(
        'sub https://panel.example.com:8443/s/AbCdEf0123456789xyz/api/me\n'
        'uuid 0b8e3c5a-1f2d-4c3b-9a8e-7d6c5b4a3f2e\n'
        'password: hunter2 "token":"t0k3n" pass=abc&x=1\n'
        'dial 203.0.113.45:443 and [2001:db8:85a3::8a2e:370:7334]:443\n'
        'key Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MGFiY2RlZg==\n'
        '21:30:05 ConstrainedInternetAccess v1.0.30',
      );
      expect(masked, contains('/s/***/api/me'));
      expect(masked, isNot(contains('AbCdEf0123456789xyz')));
      expect(masked, contains('uuid <uuid>'));
      expect(masked, isNot(contains('hunter2')));
      expect(masked, isNot(contains('t0k3n')));
      expect(masked, isNot(contains('abc&')));
      expect(masked, contains('203.0.x.x:443'));
      expect(masked, isNot(contains('370:7334')));
      expect(masked, contains('2001:db8:x:x'));
      expect(masked, contains('<redacted>'));
      expect(masked, contains('21:30:05 ConstrainedInternetAccess v1.0.30'));
    });

    test('what is copied for another provider is masked too', () {
      final body = vpsFeedbackBody(
        text: 'no line from 198.51.100.7',
        client: {'version': '1.0.31', 'platform': 'windows'},
        steps: const [(id: 'dns', ok: false, detail: 'via 192.0.2.53')],
        log: 'dial 192.0.2.10 failed',
      );
      final text = vpsFeedbackText(body);
      for (final ip in ['198.51.100.7', '192.0.2.53', '192.0.2.10']) {
        expect(text, isNot(contains(ip)));
      }
      expect(text, contains('FAIL dns'));
    });

    test('quoted secrets, URL credentials and auth headers are masked', () {
      final body = vpsFeedbackBody(
        text: 'https://alice:short-pass@panel.example.com/subscription',
        client: {'version': '1.0.33'},
        steps: const [
          (
            id: 'proxy',
            ok: false,
            detail: 'socks5://bob:p%40ss@192.0.2.10:1080',
          ),
        ],
        log:
            'password: "two words"\n'
            "pass='single quoted'\n"
            'password="escaped \\\"quote\\\" secret"\n'
            'Authorization: Bearer short-token\n'
            'Proxy-Authorization: Basic YWJjOmRlZg==\n'
            '{"Authorization":"Bearer json-token"}\n'
            'connected to https://status.example/path',
      );
      final text = vpsFeedbackText(body);
      for (final secret in [
        'alice',
        'short-pass',
        'bob',
        'p%40ss',
        'two words',
        'single quoted',
        'escaped',
        'quote',
        'short-token',
        'YWJjOmRlZg==',
        'json-token',
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      expect(text, contains('https://***@panel.example.com/subscription'));
      expect(text, contains('socks5://***@192.0.x.x:1080'));
      expect(text, contains('connected to https://status.example/path'));
    });
  });

  test('the body keeps to what the panel takes', () {
    final body = vpsFeedbackBody(
      text: '  ',
      client: {
        'version': '1.0.31',
        'platform': 'windows',
        'os': 'x' * 100,
        'Bad-Key': 'dropped',
      },
      log: [for (var i = 0; i < 4000; i++) 'line $i ${'y' * 40}'].join('\n'),
    );
    expect(body.containsKey('text'), isFalse);
    expect(body.containsKey('diagnosis'), isFalse);
    final client = body['client']! as Map;
    expect(client.keys, ['version', 'platform', 'os']);
    expect((client['os']! as String).length, 64);
    final log = body['log']! as String;
    expect(utf8.encode(log).length, lessThanOrEqualTo(60 * 1024));
    expect(log, startsWith('line '));
    expect(log, endsWith('line 3999 ${'y' * 40}'));
  });

  test("the panel's answers", () {
    expect(vpsFeedbackAnswer(200, '{"ok":true,"id":12}').id, 12);
    expect(
      vpsFeedbackAnswer(200, '{"ok":true,"id":12}').outcome,
      VpsFeedbackOutcome.sent,
    );
    final limited = vpsFeedbackAnswer(
      429,
      '{"code":"rate_limited"}',
      retry: '95',
    );
    expect(limited.outcome, VpsFeedbackOutcome.rateLimited);
    expect(limited.retryAfter, const Duration(seconds: 95));
    expect(vpsFeedbackAnswer(429, '').retryAfter, const Duration(minutes: 2));
    expect(
      vpsFeedbackAnswer(503, '{"code":"feature_off"}').outcome,
      VpsFeedbackOutcome.featureOff,
    );
    expect(
      vpsFeedbackAnswer(503, 'Service Unavailable').outcome,
      VpsFeedbackOutcome.unreachable,
    );
    expect(
      vpsFeedbackAnswer(404, 'not found').outcome,
      VpsFeedbackOutcome.linkWrong,
    );
    expect(
      vpsFeedbackAnswer(413, '{"code":"too_large"}').outcome,
      VpsFeedbackOutcome.tooLarge,
    );
    expect(
      vpsFeedbackAnswer(400, '{"code":"bad_request"}').outcome,
      VpsFeedbackOutcome.rejected,
    );
  });

  test('the member says whether feedback is on and what is unread', () {
    final on = VpsMember.fromJson({
      'features': {'feedback': true},
      'feedback_unread': 2,
    });
    expect(on.feedback, isTrue);
    expect(on.feedbackUnread, 2);
    final off = VpsMember.fromJson({'feedback_unread': 'x'});
    expect(off.feedback, isFalse);
    expect(off.feedbackUnread, 0);
  });

  group('outbox', () {
    late String? stored;
    late ProviderContainer container;
    final base = Uri.parse('https://panel.example.com/s/token/api/');

    setUp(() {
      stored = null;
      vpsFeedbackLoad = () async => stored;
      vpsFeedbackSave = (value) async => stored = value;
      container = ProviderContainer();
    });
    tearDown(() => container.dispose());

    test(
      'a note that cannot go waits, and goes once the panel answers',
      () async {
        final outbox = container.read(vpsFeedbackOutboxProvider.notifier);
        final first = await outbox.send(base, {
          'text': 'no line',
        }, (_, _) async => _answer(VpsFeedbackOutcome.unreachable));
        expect(first.outcome, VpsFeedbackOutcome.unreachable);
        expect(container.read(vpsFeedbackOutboxProvider), hasLength(1));
        expect(stored, contains('no line'));

        final restarted = ProviderContainer();
        addTearDown(restarted.dispose);
        final sent = <String>[];
        final told = <VpsFeedbackOutcome>[];
        await restarted.read(vpsFeedbackOutboxProvider.notifier).flush(
          (_, answer) => told.add(answer.outcome),
          (url, body) async {
            sent.add('$url ${body['text']}');
            return (outcome: VpsFeedbackOutcome.sent, id: 7, retryAfter: null);
          },
        );
        expect(sent, ['$base no line']);
        expect(told, [VpsFeedbackOutcome.sent]);
        expect(restarted.read(vpsFeedbackOutboxProvider), isEmpty);
        expect(jsonDecode(stored!), isEmpty);
      },
    );

    test('a rate limit or a dead network keeps the note waiting', () async {
      final outbox = container.read(vpsFeedbackOutboxProvider.notifier);
      await outbox.send(base, {
        'text': 'a',
      }, (_, _) async => _answer(VpsFeedbackOutcome.unreachable));
      for (final outcome in [
        VpsFeedbackOutcome.rateLimited,
        VpsFeedbackOutcome.unreachable,
      ]) {
        await outbox.flush(
          (_, _) => fail('nothing was sent'),
          (_, _) async => _answer(outcome),
        );
        expect(container.read(vpsFeedbackOutboxProvider), hasLength(1));
      }
    });

    test('an answer other than unreachable is not queued', () async {
      final outbox = container.read(vpsFeedbackOutboxProvider.notifier);
      for (final outcome in [
        VpsFeedbackOutcome.rateLimited,
        VpsFeedbackOutcome.featureOff,
        VpsFeedbackOutcome.tooLarge,
      ]) {
        await outbox.send(base, {
          'text': 'a',
        }, (_, _) async => _answer(outcome));
      }
      expect(container.read(vpsFeedbackOutboxProvider), isEmpty);
    });

    test('a saved note the server turned off is dropped and told', () async {
      final outbox = container.read(vpsFeedbackOutboxProvider.notifier);
      await outbox.send(base, {
        'text': 'a',
      }, (_, _) async => _answer(VpsFeedbackOutcome.unreachable));
      final told = <VpsFeedbackOutcome>[];
      await outbox.flush(
        (_, answer) => told.add(answer.outcome),
        (_, _) async => _answer(VpsFeedbackOutcome.featureOff),
      );
      expect(told, [VpsFeedbackOutcome.featureOff]);
      expect(container.read(vpsFeedbackOutboxProvider), isEmpty);
    });
  });
}
