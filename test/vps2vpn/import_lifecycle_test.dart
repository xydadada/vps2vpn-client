import 'dart:async';

import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/clipboard_import.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

const _link = 'https://example.com/subscription/fixture';

class _ProfilesAction extends ProfilesAction {
  late final gate = Completer<void>();
  final links = <String>[];

  @override
  void build() {}

  @override
  Future<void> addProfileFromLink(
    String link, {
    String? label,
    String ageSecretKey = '',
  }) async {
    links.add(link);
    await gate.future;
    ref
        .read(profilesProvider.notifier)
        .put(
          Profile(
            id: 1,
            url: link,
            autoUpdateDuration: const Duration(hours: 1),
          ),
        );
  }
}

void main() {
  late _ProfilesAction profiles;
  late ProviderContainer container;

  setUp(() {
    profiles = _ProfilesAction();
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(TestProfiles.new),
        profilesActionProvider.overrideWith(() => profiles),
      ],
    );
    globalState.container = container;
  });
  tearDown(() => container.dispose());

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          locale: const Locale('en'),
          child: Center(child: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a mounted import still reports the added subscription', (
    tester,
  ) async {
    late WidgetRef ref;
    await pump(
      tester,
      Consumer(
        builder: (_, value, _) {
          ref = value;
          return const SizedBox();
        },
      ),
    );
    final result = vpsImportLink(ref, _link);
    profiles.gate.complete();
    expect(await result, VpsImportResult.added);
    expect(container.read(profilesProvider).single.url, _link);
  });

  testWidgets(
    'disposing the import view does not interrupt the saved profile',
    (tester) async {
      late WidgetRef ref;
      await pump(
        tester,
        Consumer(
          builder: (_, value, _) {
            ref = value;
            return const SizedBox();
          },
        ),
      );
      final result = vpsImportLink(ref, _link);
      await pump(tester, const SizedBox());
      profiles.gate.complete();
      await expectLater(result, completion(VpsImportResult.failed));
      expect(container.read(profilesProvider).single.url, _link);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing the real import field ignores its late UI completion', (
    tester,
  ) async {
    var addedCallbacks = 0;
    await pump(
      tester,
      SizedBox(
        width: 500,
        child: VpsImportField(onAdded: () => addedCallbacks++),
      ),
    );
    await tester.enterText(find.byType(EditableText), _link);
    await tester.tap(find.widgetWithText(VpsButton, 'Import'));
    await tester.pump();
    expect(profiles.links, [_link]);
    await pump(tester, const SizedBox());
    profiles.gate.complete();
    await tester.pumpAndSettle();
    expect(container.read(profilesProvider).single.url, _link);
    expect(addedCallbacks, 0);
    expect(tester.takeException(), isNull);
  });
}
