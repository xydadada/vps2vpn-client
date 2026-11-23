import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/vps2vpn/flags.dart';
import 'package:fl_clash/vps2vpn/tray_menu.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_api/tray.dart';

TrayState _state({bool isStart = false, Mode mode = Mode.rule}) => TrayState(
  mode: mode,
  port: 7890,
  autoLaunch: false,
  systemProxy: true,
  tunEnable: false,
  isStart: isStart,
  groups: const [],
  selectedMap: const {},
  showTrayTitle: false,
  safeMode: false,
);

List<String> _labels(List<TrayMenuItem> items) => [
  for (final item in items)
    switch (item) {
      TrayMenuAction(:final label) => label,
      TrayMenuCheckbox(:final label) => label,
      _ => '-',
    },
];

void main() {
  setUp(() => vps2vpnUpstreamUi = false);
  tearDown(() => vps2vpnUpstreamUi = true);

  List<TrayMenuItem> menu(TrayState state) => vpsTrayMenu(
    state: state,
    read: <T>(_) => throw UnimplementedError(),
    onShow: () {},
    onExit: () {},
  )!;

  test('the tray says Connect or Disconnect, like the window', () {
    expect(_labels(menu(_state())), contains('Connect'));
    expect(_labels(menu(_state(isStart: true))), contains('Disconnect'));
    expect(_labels(menu(_state(isStart: true))).first, 'Connected');
  });

  test('the tray offers no direct mode', () {
    final labels = _labels(menu(_state()));
    expect(labels, containsAll(['Rule mode', 'Global mode']));
    expect(labels.where((l) => l.toLowerCase().contains('direct')), isEmpty);
  });

  test('advanced mode keeps the full menu', () {
    vps2vpnUpstreamUi = true;
    expect(
      vpsTrayMenu(
        state: _state(),
        read: <T>(_) => throw UnimplementedError(),
        onShow: () {},
        onExit: () {},
      ),
      isNull,
    );
  });
}
