import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/simple_mode.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' show ColorScheme, Theme, ThemeData;

import '../helpers/test_app.dart';

Future<(ColorScheme, VpsPalette)> _dressed(WidgetTester tester) async {
  late ColorScheme scheme;
  late VpsPalette palette;
  await tester.pumpWidget(
    TestApp(
      includeNavigatorKey: false,
      child: Theme(
        data: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: vpsCoral,
            brightness: Brightness.dark,
          ),
        ),
        child: Builder(
          builder: (context) => vpsDressAlert(
            context,
            Builder(
              builder: (context) {
                scheme = Theme.of(context).colorScheme;
                palette = VpsPalette.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    ),
  );
  return (scheme, palette);
}

void main() {
  tearDown(() {
    vps2vpnUpstreamUi = true;
    vps2vpnAdvancedMode = false;
  });

  testWidgets("simple mode's alert button is its accent with white text", (
    tester,
  ) async {
    vps2vpnUpstreamUi = false;
    final (scheme, p) = await _dressed(tester);
    expect(scheme.primary, p.accent);
    expect(scheme.onPrimary, p.accentInk);
  });

  testWidgets("advanced mode keeps FlClash's own alert colours", (
    tester,
  ) async {
    vps2vpnUpstreamUi = false;
    vps2vpnAdvancedMode = true;
    final (scheme, _) = await _dressed(tester);
    final own = ColorScheme.fromSeed(
      seedColor: vpsCoral,
      brightness: Brightness.dark,
    );
    expect(scheme.primary, own.primary);
    expect(scheme.onPrimary, own.onPrimary);
  });
}
