import 'dart:io';

final _path = Platform.environment['VPS2VPN_UI_TRACE'];

/// Appends [line] to the file CI names in `VPS2VPN_UI_TRACE`, so an end to
/// end check can tell which dialogs, banners and update checks a run saw.
void vpsUiTrace(String line) {
  final path = _path;
  if (path == null || path.isEmpty) return;
  try {
    File(path).writeAsStringSync(
      '${DateTime.now().toIso8601String()} ${line.replaceAll('\n', ' | ')}\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}
