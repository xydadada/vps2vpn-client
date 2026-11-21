import 'dart:async';

import 'package:fl_clash/common/link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/audit-links');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'cancelling before takeLinks returns discards the delayed batch',
    () async {
      final asked = Completer<void>();
      final reply = Completer<List<String>>();
      messenger.setMockMethodCallHandler(channel, (call) {
        asked.complete();
        return reply.future;
      });
      final received = <Uri>[];
      final errors = <Object>[];
      final subscription = androidLinks(
        channel,
      ).listen(received.add, onError: errors.add);
      await asked.future;
      await subscription.cancel();
      reply.complete([
        'flclash://install-config?url=https://example.com/private',
      ]);
      await pumpEventQueue();

      expect(received, isEmpty);
      expect(errors, isEmpty);
    },
  );

  test('takeLinks platform failures are delivered as stream errors', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'unavailable');
    });
    final errors = <Object>[];
    final subscription = androidLinks(
      channel,
    ).listen((_) {}, onError: errors.add);
    await pumpEventQueue();

    expect(errors, [isA<PlatformException>()]);
    await subscription.cancel();
  });

  test(
    'a late takeLinks failure after cancellation is already handled',
    () async {
      final asked = Completer<void>();
      final reply = Completer<List<String>>();
      messenger.setMockMethodCallHandler(channel, (call) {
        asked.complete();
        return reply.future;
      });
      final errors = <Object>[];
      final subscription = androidLinks(
        channel,
      ).listen((_) {}, onError: errors.add);
      await asked.future;
      await subscription.cancel();
      reply.completeError(PlatformException(code: 'closed'));
      await pumpEventQueue();

      expect(errors, isEmpty);
    },
  );

  group('LinkManager errors and sensitive links', () {
    late StreamController<Uri> links;
    late Stream<Uri> Function() originalLinks;
    late DebugPrintCallback originalPrint;
    late List<String> logs;

    setUp(() {
      originalLinks = linkManager.uriLinkStream;
      originalPrint = debugPrint;
      links = StreamController<Uri>.broadcast();
      linkManager.uriLinkStream = () => links.stream;
      logs = [];
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
    });

    tearDown(() async {
      linkManager.destroy();
      await links.close();
      linkManager.uriLinkStream = originalLinks;
      debugPrint = originalPrint;
    });

    test(
      'logs neither subscription credentials nor callback exception text',
      () async {
        final handled = Completer<void>();
        final received = <String>[];
        await linkManager.initAppLinksListen((String url) {
          received.add(url);
          return handled.future;
        });
        const url = 'https://example.com/sub?token=private-token';
        links.add(
          Uri.parse('flclash://install-config?url=${Uri.encodeComponent(url)}'),
        );
        await pumpEventQueue();
        handled.completeError(StateError('Failed to fetch $url'));
        await pumpEventQueue();

        expect(received, [url]);
        expect(logs.join('\n'), contains('App link handling failed'));
        expect(logs.join('\n'), isNot(contains('private-token')));
        expect(logs.join('\n'), isNot(contains('example.com')));
      },
    );

    test(
      'stream errors and malformed UTF-8 query values do not end listening',
      () async {
        final received = <String>[];
        await linkManager.initAppLinksListen(received.add);
        links.addError(StateError('private-token'));
        links.add(Uri.parse('flclash://install-config?url=%FF'));
        links.add(
          Uri.parse('flclash://install-config?url=https://example.com/ok'),
        );
        await pumpEventQueue();

        expect(received, ['https://example.com/ok']);
        expect(logs.join('\n'), contains('App link stream failed'));
        expect(logs.join('\n'), isNot(contains('private-token')));
      },
    );
  });
}
