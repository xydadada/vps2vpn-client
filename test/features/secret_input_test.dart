import 'package:fl_clash/features/form/form_row.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  testWidgets('revealing a secret keeps keyboard learning and rewriting off', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'key-"literal"');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      TestApp(
        child: Center(
          child: SizedBox(
            width: 400,
            child: FormRowSecretTextField(controller: controller),
          ),
        ),
      ),
    );

    Future<void> expectPrivateInput(bool obscured) async {
      await tester.showKeyboard(find.byType(EditableText));
      await tester.pump();
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.obscureText, obscured);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      expect(field.smartDashesType, SmartDashesType.disabled);
      expect(field.smartQuotesType, SmartQuotesType.disabled);
      expect(controller.text, 'key-"literal"');
    }

    await expectPrivateInput(true);
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    await expectPrivateInput(false);
  });
}
