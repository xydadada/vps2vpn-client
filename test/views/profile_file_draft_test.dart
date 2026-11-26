import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:code_forge/code_forge.dart';
import 'package:file_picker/file_picker.dart';
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
import '../helpers/context_menu.dart';
import '../helpers/test_app.dart';
import '../plugins/code_forge/support.dart' show initEditorNative, settle;

class _NoopSetup extends SetupAction {
  @override
  void autoApplyProfile() {}
}

final class _PickedFile extends PlatformFile {
  final Uint8List data = Uint8List.fromList(utf8.encode('mode: direct\n'));

  @override
  Future<Uint8List> readAsBytes() async => data;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Picker extends FilePickerPlatform {
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => _PickedFile();
}

void main() {
  setUpAll(initEditorNative);

  for (final editedBeforeUpload in [false, true]) {
    testWidgets(
      'editing opens uploaded bytes, prior edit: $editedBeforeUpload',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync('profile_draft');
        addTearDown(() => directory.deleteSync(recursive: true));
        final profile = Profile.normal(label: 'Local profile');
        final file = (await tester.runAsync(() async {
          await useAppPaths(directory);
          final file = await profile.file;
          await file.parent.create(recursive: true);
          await file.writeAsString('mode: rule\n');
          return file;
        }))!;
        final previousPicker = FilePickerPlatform.instance;
        FilePickerPlatform.instance = _Picker();
        addTearDown(() => FilePickerPlatform.instance = previousPicker);
        final container = ProviderContainer(
          overrides: [setupActionProvider.overrideWith(_NoopSetup.new)],
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
        final row = find.widgetWithText(
          DecorationListItem,
          currentAppLocalizations.profile,
        );
        if (editedBeforeUpload) {
          await tester.tap(row);
          await settle(tester, 20);
          final context = tester.element(find.byType(EditorPage));
          Navigator.of(
            context,
          ).pop(Uint8List.fromList(utf8.encode('mode: global\n')));
          await settle(tester, 20);
        }
        await rightClick(tester, row);
        await settle(tester, 10);
        await tester.tap(find.text(currentAppLocalizations.upload));
        await settle(tester, 10);
        await tester.tap(row);
        await settle(tester, 20);
        expect(tester.takeException(), isNull);
        final editor = tester.widget<CodeForge>(find.byType(CodeForge));
        expect(editor.controller.text, 'mode: direct\n');
        expect(await tester.runAsync(file.readAsString), 'mode: rule\n');
      },
    );
  }
}
