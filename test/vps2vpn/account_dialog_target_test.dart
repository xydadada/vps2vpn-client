import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/devices.dart';
import 'package:fl_clash/vps2vpn/feedback.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:prism_ui/prism_ui.dart' show TextButton, TextField;

import '../helpers/host_scaffold.dart';
import '../helpers/test_app.dart';

const _a = Profile(
  id: 1,
  autoUpdateDuration: Duration.zero,
  type: ProfileType.url,
  label: 'Account A',
  url: 'https://a.example.com/s/AAAAAAAAAAAAAAAA',
);
const _b = Profile(
  id: 2,
  autoUpdateDuration: Duration.zero,
  type: ProfileType.url,
  label: 'Account B',
  url: 'https://b.example.com/s/BBBBBBBBBBBBBBBB',
);

class _Selected extends Notifier<Profile?> {
  @override
  Profile? build() => _a;

  void select(Profile? profile) => state = profile;
}

final _selected = NotifierProvider<_Selected, Profile?>(_Selected.new);

typedef _Call = ({Uri base, String path, Map<String, Object?>? body});

class _Outbox extends VpsFeedbackOutbox {
  final sent = <Uri>[];
  final replyBases = <Uri>[];
  final reply = Completer<List<VpsFeedbackItem>?>();
  Completer<VpsFeedbackAnswer>? pendingSend;

  @override
  Future<List<VpsFeedbackItem>?> replies(Uri base) {
    replyBases.add(base);
    return reply.future;
  }

  @override
  Future<VpsFeedbackAnswer> send(
    Uri base,
    Map<String, Object?> body, [
    VpsFeedbackPost? post,
  ]) async {
    sent.add(base);
    return pendingSend?.future ??
        Future.value((
          outcome: VpsFeedbackOutcome.rateLimited,
          id: null,
          retryAfter: null,
        ));
  }
}

Future<ProviderContainer> _host(
  WidgetTester tester, {
  required List<_Call> calls,
  _Outbox? outbox,
  Completer<(int, String, String?)>? mutation,
}) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      currentProfileProvider.overrideWith((ref) => ref.watch(_selected)),
      currentGroupsStateProvider.overrideWithValue(
        const GroupsState(value: []),
      ),
      isStartProvider.overrideWithValue(false),
      vpsMemberProvider.overrideWith(
        (ref) async => const VpsMemberResult(
          member: VpsMember(
            name: 'Example account',
            enabled: true,
            feedback: true,
            devices: true,
          ),
        ),
      ),
      vpsDeviceCallsProvider.overrideWithValue(
        (base) => (path, {body, headers = const {}}) async {
          calls.add((base: base, path: path, body: body));
          if (body != null && mutation != null) return mutation.future;
          return (
            200,
            jsonEncode({
              'ok': true,
              'devices': [
                {
                  'device_id': 'example-device',
                  'name': 'Example phone',
                  'platform': 'android',
                  'revoked': false,
                },
              ],
            }),
            null,
          );
        },
      ),
      if (outbox != null) vpsFeedbackOutboxProvider.overrideWith(() => outbox),
    ],
  );
  addTearDown(container.dispose);
  globalState.container = container;
  globalState.packageInfo = PackageInfo(
    appName: 'vps2vpn',
    packageName: 'example.client',
    version: '1.0.34',
    buildNumber: '1',
  );
  container
      .read(viewSizeProvider.notifier)
      .update((_) => const Size(1000, 900));
  await container.read(vpsMemberProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const TestApp(locale: Locale('en'), child: HostScaffold()),
    ),
  );
  await tester.pump();
  return container;
}

VpsButton _deviceButton(WidgetTester tester, String label) =>
    tester.widget<VpsButton>(
      find.ancestor(of: find.text(label), matching: find.byType(VpsButton)),
    );

TextButton _dialogButton(WidgetTester tester, String label) =>
    tester.widget<TextButton>(
      find.ancestor(of: find.text(label), matching: find.byType(TextButton)),
    );

void main() {
  final load = vpsDeviceLoad;
  final save = vpsDeviceSave;
  setUp(() {
    vpsDeviceLoad = (_) async => '00000000-0000-4000-8000-000000000001';
    vpsDeviceSave = (_, _) async {};
  });
  tearDown(() {
    vpsDeviceLoad = load;
    vpsDeviceSave = save;
  });

  for (final next in <Profile?>[_b, _a.copyWith(url: _b.url), null]) {
    testWidgets('device actions stop when the opening profile changes to '
        '${next?.id ?? 'deleted'} / ${next == _b ? 'other' : 'changed'}', (
      tester,
    ) async {
      final calls = <_Call>[];
      final container = await _host(tester, calls: calls);
      final closed = vpsShowDevices();
      await tester.pumpAndSettle();
      final remove = _deviceButton(tester, 'Remove').onTap!;
      container.read(_selected.notifier).select(next);
      remove();
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.body != null), isEmpty);
      expect(find.text('Remove'), findsNothing);
      expect(find.text('Sign out other devices'), findsNothing);
      expect(find.textContaining('subscription changed'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await closed;
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('same-profile device operations retain their target', (
    tester,
  ) async {
    final calls = <_Call>[];
    await _host(tester, calls: calls);
    final closed = vpsShowDevices();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    final writes = calls.where((call) => call.body != null).toList();
    expect(writes, hasLength(1));
    expect(writes.single.base, vpsApiBase(_a.url));
    expect(writes.single.path, 'devices/example-device/revoke');
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await closed;
  });

  testWidgets('late device completion does not reload a different account', (
    tester,
  ) async {
    final calls = <_Call>[];
    final mutation = Completer<(int, String, String?)>();
    final container = await _host(tester, calls: calls, mutation: mutation);
    final closed = vpsShowDevices();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pump();
    container.read(_selected.notifier).select(_b);
    mutation.complete((200, '{"ok":true}', null));
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.base), everyElement(vpsApiBase(_a.url)));
    expect(calls.where((call) => call.path == 'devices'), hasLength(1));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await closed;
  });

  testWidgets('sign-out confirmation cannot target a newly selected account', (
    tester,
  ) async {
    final calls = <_Call>[];
    final container = await _host(tester, calls: calls);
    final closed = vpsShowDevices(confirmKick: true);
    await tester.pumpAndSettle();
    final confirm = _dialogButton(tester, 'Sign out').onPressed!;
    container.read(_selected.notifier).select(_b);
    confirm();
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.body != null), isEmpty);
    expect(find.text('Sign out'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await closed;
  });

  testWidgets('feedback keeps the draft and refuses a stale Send callback', (
    tester,
  ) async {
    final outbox = _Outbox();
    final container = await _host(tester, calls: [], outbox: outbox);
    final closed = vpsShowFeedback();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Example draft');
    await tester.pump();
    final send = _dialogButton(tester, 'Send').onPressed!;
    container.read(_selected.notifier).select(_b);
    send();
    await tester.pumpAndSettle();
    expect(outbox.sent, isEmpty);
    expect(outbox.replyBases, [vpsApiBase(_a.url)]);
    expect(find.text('Example draft'), findsOneWidget);
    expect(find.text('Send'), findsNothing);
    expect(find.text('Copy details'), findsOneWidget);
    expect(find.textContaining('sending is paused'), findsOneWidget);
    outbox.reply.complete([]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await closed;
  });

  testWidgets('late feedback completion does not close the changed dialog', (
    tester,
  ) async {
    final outbox = _Outbox()..pendingSend = Completer<VpsFeedbackAnswer>();
    final container = await _host(tester, calls: [], outbox: outbox);
    final closed = vpsShowFeedback();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep this draft');
    await tester.pump();
    await tester.tap(find.text('Send'));
    await tester.pump();
    container.read(_selected.notifier).select(_b);
    outbox.pendingSend!.complete((
      outcome: VpsFeedbackOutcome.sent,
      id: 1,
      retryAfter: null,
    ));
    await tester.pumpAndSettle();
    expect(outbox.sent, [vpsApiBase(_a.url)]);
    expect(find.text('Keep this draft'), findsOneWidget);
    expect(find.textContaining('sending is paused'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await closed;
    outbox.reply.complete([]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'copied feedback keeps the diagnostics captured for its account',
    (tester) async {
      final outbox = _Outbox();
      final container = await _host(tester, calls: [], outbox: outbox);
      container.read(logsProvider.notifier).add(Log.app('account A marker'));
      final closed = vpsShowFeedback();
      await tester.pumpAndSettle();
      container.read(_selected.notifier).select(_b);
      container.read(logsProvider.notifier).add(Log.app('account B marker'));
      await tester.pumpAndSettle();
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.text('Copy details'));
      await tester.pump();
      expect(copied, contains('account A marker'));
      expect(copied, isNot(contains('account B marker')));
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await closed;
      outbox.reply.complete([]);
      await tester.pump();
    },
  );
}
