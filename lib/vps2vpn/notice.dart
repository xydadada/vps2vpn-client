// The notices under a page title: a status dot, a few lines, and × or one
// action. Errors land here too instead of floating over the title.

import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/flags.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class VpsNotice extends StatelessWidget {
  const VpsNotice({
    super.key,
    required this.color,
    required this.lines,
    this.action,
    this.actions = const [],
    this.onDismiss,
  });

  final Color color;

  /// The first line is the headline; the rest explain it.
  final List<String> lines;

  /// Stands where × would.
  final Widget? action;

  /// Buttons under the lines.
  final List<Widget> actions;

  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final single = lines.length == 1 && actions.isEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: VpsCard(
        padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
        child: Row(
          crossAxisAlignment: single
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(top: single ? 0 : 5),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (i, line) in lines.indexed)
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                      child: Text(
                        line,
                        style: vpsText(
                          p,
                          size: 13,
                          color: i == 0 ? p.text : p.soft,
                          height: 1.45,
                        ),
                      ),
                    ),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(spacing: 10, runSpacing: 10, children: actions),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (action != null)
              action!
            else if (onDismiss != null)
              VpsPressable(
                onTap: onDismiss,
                semanticLabel: tr(context, '关闭提示', 'Dismiss'),
                child: SizedBox.square(
                  dimension: 32,
                  child: Center(
                    child: Text(
                      '×',
                      style: vpsText(p, size: 18, color: p.muted),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final vpsPageError = ValueNotifier<String?>(null);

/// Installed as [Dialogs.pinError] while the simple pages show.
bool vpsPinError(String text) {
  if (vps2vpnAdvancedMode || vps2vpnUpstreamUi) return false;
  vpsPageError.value = text;
  return true;
}

class VpsErrorNotice extends ConsumerWidget {
  const VpsErrorNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(isStartProvider, (_, now) {
      if (now) vpsPageError.value = null;
    });
    final p = VpsPalette.of(context);
    return ValueListenableBuilder<String?>(
      valueListenable: vpsPageError,
      builder: (context, text, _) => text == null
          ? const SizedBox.shrink()
          : VpsNotice(
              color: p.bad,
              lines: [text],
              onDismiss: () => vpsPageError.value = null,
            ),
    );
  }
}
