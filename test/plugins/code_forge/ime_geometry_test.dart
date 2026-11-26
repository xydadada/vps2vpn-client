import 'package:code_forge/code_forge.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

List<MethodCall> _geometry(WidgetTester tester) => tester.testTextInput.log
    .where((call) => call.method == 'TextInput.setEditableSizeAndTransform')
    .toList();

void main() {
  setUpAll(initEditorNative);

  testWidgets('IME geometry follows a moved editor with an unchanged caret', (
    tester,
  ) async {
    final controller = CodeForgeController()..text = 'name: value';
    final shift = ValueNotifier(Offset.zero);
    addTearDown(shift.dispose);
    await pumpEditor(
      tester,
      controller,
      wrap: (editor) => ValueListenableBuilder(
        valueListenable: shift,
        builder: (_, offset, child) =>
            Transform.translate(offset: offset, child: child),
        child: editor,
      ),
    );
    await focusEditor(tester);
    final before = _geometry(tester);
    final transform = (before.last.arguments as Map)['transform'] as List;
    final caret = controller.selection;

    shift.value = const Offset(18, 24);
    controller.searchHighlights = const [];
    await tester.pump();
    final after = _geometry(tester);
    final moved = (after.last.arguments as Map)['transform'] as List;
    expect(controller.selection, caret);
    expect(after.length, before.length + 1);
    expect(moved[12], (transform[12] as num) + 18);
    expect(moved[13], (transform[13] as num) + 24);

    controller.searchHighlights = const [];
    await tester.pump();
    expect(_geometry(tester), hasLength(after.length));
  });

  testWidgets('a reopened input connection receives its caret geometry', (
    tester,
  ) async {
    final controller = CodeForgeController()..text = 'name: value';
    await pumpEditor(tester, controller);
    await focusEditor(tester);
    final before = _geometry(tester).length;
    final caret = controller.selection;
    await pumpEditor(tester, controller, readOnly: true);
    expect(controller.connection, isNull);

    await pumpEditor(tester, controller);
    expect(controller.connection?.attached, isTrue);
    expect(controller.selection, caret);
    expect(_geometry(tester), hasLength(before + 1));
  });
}
