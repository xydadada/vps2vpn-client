import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/pages/editor.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/profiles/edit.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_paths.dart';
import '../helpers/test_app.dart';
import '../plugins/code_forge/support.dart' show initEditorNative, settle;

class _NoopSetup extends SetupAction {
  @override
  void autoApplyProfile() {}
}

class _Validation extends ProfilesAction {
  _Validation(this.result);

  final String result;

  @override
  Future<String?> validateConfigWithData(List<int> data) async {
    if (result == 'error') {
      throw const MessageException('Validation unavailable');
    }
    return result == 'invalid' ? 'Invalid configuration' : null;
  }
}

void main() {
  setUpAll(initEditorNative);

  for (final result in ['error', 'invalid', 'valid']) {
    testWidgets('profile editor handles validation $result', (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'profile_validation',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final profile = Profile.normal(label: 'Local profile');
      final file = (await tester.runAsync(() async {
        await useAppPaths(directory);
        final file = await profile.file;
        await file.parent.create(recursive: true);
        await file.writeAsString('mode: rule\n');
        return file;
      }))!;
      final container = ProviderContainer(
        overrides: [
          setupActionProvider.overrideWith(_NoopSetup.new),
          profilesActionProvider.overrideWith(() => _Validation(result)),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(() async => tester.pumpWidget(const SizedBox()));
      globalState.container = container;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TestApp(
            locale: const Locale('en'),
            child: EditProfileView(profile: profile),
          ),
        ),
      );
      await settle(tester, 20);
      await tester.tap(find.widgetWithText(DecorationListItem, 'Profile'));
      await settle(tester, 20);
      final page = find.byType(EditorPage);
      final editor = tester.widget<EditorPage>(page);
      unawaited(
        Future.sync(
          () => editor.onSave!(
            tester.element(page),
            'Local profile',
            const EditorContent.text('mode: direct\n'),
          ),
        ),
      );
      await settle(tester, 20);
      expect(tester.takeException(), isNull);
      if (result == 'valid') {
        expect(page, findsNothing);
      } else {
        expect(
          find.text(
            result == 'error'
                ? 'Validation unavailable'
                : 'Invalid configuration',
            findRichText: true,
          ),
          findsOneWidget,
        );
        await tester.tap(find.text(currentAppLocalizations.confirm));
        await settle(tester, 20);
        expect(page, findsOneWidget);
      }
      expect(await tester.runAsync(file.readAsString), 'mode: rule\n');
    });
  }
}
