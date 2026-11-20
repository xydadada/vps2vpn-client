import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/mine.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

const profile = Profile(
  id: 1,
  type: ProfileType.url,
  label: 'First',
  url: 'https://example.invalid/s/AbCdEf0123456789xyzQ',
  autoUpdateDuration: Duration(hours: 1),
);

class PanelTransport extends HttpOverrides {
  int gets = 0;
  int posts = 0;
  int status = 200;
  String body = '{"name":"Before","enabled":true}';

  @override
  HttpClient createHttpClient(SecurityContext? context) => PanelClient(this);
}

class PanelClient implements HttpClient {
  PanelClient(this.transport);
  final PanelTransport transport;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    transport.gets++;
    return PanelRequest(transport);
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    transport.posts++;
    return PanelRequest(transport);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class PanelHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class PanelRequest implements HttpClientRequest {
  PanelRequest(this.transport);
  final PanelTransport transport;

  @override
  final HttpHeaders headers = PanelHeaders();

  @override
  void add(List<int> data) {}

  @override
  Future<HttpClientResponse> close() async =>
      PanelResponse(transport.status, transport.body);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class PanelResponse extends Stream<List<int>> implements HttpClientResponse {
  PanelResponse(this.statusCode, String body)
    : stream = Stream.value(utf8.encode(body));

  @override
  final int statusCode;
  final Stream<List<int>> stream;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FailingFirstProfileAction extends ProfilesAction {
  final calls = <int>[];

  @override
  Future<void> updateProfile(
    Profile profile, {
    bool showLoading = false,
  }) async {
    calls.add(profile.id);
    if (profile.id == 1) throw const SocketException('offline fixture');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an active member listener refreshes after five minutes', (
    tester,
  ) async {
    final transport = PanelTransport();
    final old = HttpOverrides.current;
    HttpOverrides.global = transport;
    addTearDown(() => HttpOverrides.global = old);
    final container = ProviderContainer(
      overrides: [
        currentProfileProvider.overrideWithValue(profile),
        isStartProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    container.listen(vpsMemberProvider, (_, _) {});
    await tester.pump();
    expect(container.read(vpsMemberProvider).value?.member?.name, 'Before');
    transport.body = '{"name":"After","enabled":false}';
    await tester.pump(const Duration(minutes: 5));
    await tester.pump();
    expect(transport.gets, 2);
    expect(container.read(vpsMemberProvider).value?.member?.name, 'After');
  });

  testWidgets(
    'a failed first member fetch retries and disposal stops polling',
    (tester) async {
      final transport = PanelTransport()..status = 500;
      final old = HttpOverrides.current;
      HttpOverrides.global = transport;
      addTearDown(() => HttpOverrides.global = old);
      final container = ProviderContainer(
        overrides: [
          currentProfileProvider.overrideWithValue(profile),
          isStartProvider.overrideWithValue(false),
        ],
      );
      final subscription = container.listen(vpsMemberProvider, (_, _) {});
      await tester.pump();
      expect(
        container.read(vpsMemberProvider).value?.problem,
        VpsPanelProblem.unreachable,
      );
      transport.status = 200;
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(transport.gets, 2);
      expect(container.read(vpsMemberProvider).value?.member?.name, 'Before');
      subscription.close();
      container.dispose();
      await tester.pump(const Duration(minutes: 6));
      expect(transport.gets, 2);
    },
  );

  testWidgets(
    'default update all attempts later subscriptions after a failure',
    (tester) async {
      final action = FailingFirstProfileAction();
      final container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(
            () => TestProfiles([
              profile,
              profile.copyWith(
                id: 2,
                label: 'Second',
                url: 'https://second.invalid/sub',
              ),
            ]),
          ),
          profilesActionProvider.overrideWith(() => action),
          vpsMemberProvider.overrideWith((ref) async => null),
          localIpProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      globalState.container = container;
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TestApp(locale: Locale('en'), child: VpsMePage()),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Update all'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(action.calls, [1, 2]);
      // The failure is shown in the app banner (outside this test tree).
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'buttons support Tab, Enter and Space and skip disabled controls',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        TestApp(
          includeNavigatorKey: false,
          child: Column(
            children: [
              VpsButton(label: 'First', onTap: () => taps++),
              const VpsButton(label: 'Disabled', onTap: null),
              VpsButton(label: 'Last', onTap: () => taps += 10),
            ],
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(taps, 2);
      expect(
        find.byWidgetPredicate((w) {
          if (w is! DecoratedBox || w.decoration is! ShapeDecoration) {
            return false;
          }
          final shape = (w.decoration as ShapeDecoration).shape;
          return shape is RoundedSuperellipseBorder && shape.side.width == 2;
        }),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(taps, 12);
    },
  );

  testWidgets('a switch retains its name and toggled semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    addTearDown(semantics.dispose);
    await tester.pumpWidget(
      TestApp(
        includeNavigatorKey: false,
        child: VpsRow(
          icon: VpsIcon.shield,
          title: 'Take over',
          trailing: VpsSwitch(value: true, onChanged: (_) {}),
        ),
      ),
    );
    final node = tester.getSemantics(find.byType(MergeSemantics));
    expect(node.label, contains('Take over'));
    expect(node.hasFlag(SemanticsFlag.hasToggledState), isTrue);
    expect(node.hasFlag(SemanticsFlag.isToggled), isTrue);
  });
}
