import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/profiles/edit.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

const _original = Profile(
  id: 42,
  type: ProfileType.custom,
  label: 'Original',
  url: 'https://original.invalid/sub',
  autoUpdateDuration: Duration(hours: 1),
);

Future<TestProfiles> _openRename(WidgetTester tester) async {
  final profiles = TestProfiles([_original]);
  final container = ProviderContainer(
    overrides: [profilesProvider.overrideWith(() => profiles)],
  );
  addTearDown(container.dispose);
  container.read(profilesProvider);
  globalState.container = container;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TestApp(
        locale: const Locale('en'),
        child: Consumer(
          builder: (context, ref, _) => Center(
            child: TextButton(
              onPressed: () => renameProfile(context, ref, _original),
              child: const Text('Open rename'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open rename'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(EditableText), 'Renamed');
  return profiles;
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.text(currentAppLocalizations.submit));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('rename preserves changes made while the dialog is open', (
    tester,
  ) async {
    final profiles = await _openRename(tester);
    final latest = _original.copyWith(
      url: 'https://replacement.invalid/sub',
      lastUpdateDate: DateTime(2026, 1, 2),
      autoUpdateDuration: const Duration(hours: 3),
    );
    profiles.put(latest);
    await _confirm(tester);
    expect(globalState.container.read(profilesProvider), [
      latest.copyWith(label: 'Renamed'),
    ]);
  });

  testWidgets('rename does not restore a profile deleted while it waits', (
    tester,
  ) async {
    final profiles = await _openRename(tester);
    await profiles.del(_original.id);
    await _confirm(tester);
    expect(globalState.container.read(profilesProvider), isEmpty);
  });
}
