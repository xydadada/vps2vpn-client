import 'dart:async';

import 'package:fl_clash/common/link.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum VpsImportResult { added, noLink, failed }

/// The subscription link on the clipboard. A plain URL, a share link, or a
/// clash://install-config?url=… wrapper all come down to one link; [strict]
/// keeps only a vps2vpn subscription, so an ordinary web address is no offer.
Future<String?> vpsClipboardLink({bool strict = false}) async {
  final String? text;
  try {
    text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  } catch (_) {
    return null;
  }
  final raw = profileUrlFromQrCodes([text]);
  if (raw == null) return null;
  final link = vpsSubscriptionLink(raw);
  return !strict || vpsApiBase(link) != null ? link : null;
}

Future<VpsImportResult> vpsImportLink(WidgetRef ref, String link) async {
  final before = ref.read(profilesProvider).length;
  await ref.read(profilesActionProvider.notifier).addProfileFromLink(link);
  return ref.read(profilesProvider).length > before
      ? VpsImportResult.added
      : VpsImportResult.failed;
}

Future<VpsImportResult> vpsImportClipboard(WidgetRef ref) async {
  final link = await vpsClipboardLink();
  if (link == null) return VpsImportResult.noLink;
  return vpsImportLink(ref, link);
}

String? vpsImportNote(
  BuildContext context,
  VpsImportResult result,
) => switch (result) {
  VpsImportResult.added => null,
  VpsImportResult.noLink => tr(
    context,
    '剪贴板里没有订阅链接。请先复制管理员发给你的链接，再点导入。',
    'No subscription link on the clipboard. Copy the link the owner gave you, then tap Import.',
  ),
  VpsImportResult.failed => tr(
    context,
    '没有导入：请确认链接完整、服务器在线，然后再试一次。',
    'Not added. Check the link is complete and the server is up, then try again.',
  ),
};

/// Offers a vps2vpn subscription found on the clipboard, at start and each
/// time the window comes back, once per link. Nothing is imported until the
/// button is pressed, and the link itself is never shown.
class VpsClipboardOffer extends ConsumerStatefulWidget {
  const VpsClipboardOffer({super.key});

  @override
  ConsumerState<VpsClipboardOffer> createState() => _VpsClipboardOfferState();
}

class _VpsClipboardOfferState extends ConsumerState<VpsClipboardOffer> {
  static final _seen = <int>{};
  late final AppLifecycleListener _lifecycle;
  String? _link;
  bool _busy = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _look);
    unawaited(_look());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _look() async {
    if (_busy) return;
    final link = await vpsClipboardLink(strict: true);
    if (!mounted || link == null || _seen.contains(link.hashCode)) return;
    final known = ref.read(profilesProvider).any((p) => p.url == link);
    if (known) return;
    setState(() {
      _link = link;
      _note = null;
    });
  }

  void _dismiss() {
    final link = _link;
    if (link != null) _seen.add(link.hashCode);
    setState(() => _link = null);
  }

  Future<void> _import() async {
    final link = _link;
    if (link == null || _busy) return;
    setState(() => _busy = true);
    final result = await vpsImportLink(ref, link);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = vpsImportNote(context, result);
      if (result == VpsImportResult.added) {
        _seen.add(link.hashCode);
        _link = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_link == null) return const SizedBox.shrink();
    final p = VpsPalette.of(context);
    final first = ref.watch(profilesProvider.select((s) => s.isEmpty));
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: VpsCard(
        padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                VpsIconView(VpsIcon.paste, size: 20, color: p.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        first
                            ? tr(
                                context,
                                '剪贴板里有一个订阅链接',
                                'There is a subscription link on your clipboard',
                              )
                            : tr(
                                context,
                                '剪贴板里有一个新的订阅链接',
                                'There is a new subscription link on your clipboard',
                              ),
                        style: vpsText(p, size: 14, weight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _note ?? tr(context, '要导入它吗？', 'Add it?'),
                        style: vpsText(
                          p,
                          size: 12.5,
                          color: _note == null ? p.soft : p.warn,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                VpsButton(
                  label: tr(context, '忽略', 'Ignore'),
                  onTap: _busy ? null : _dismiss,
                ),
                VpsButton(
                  label: _busy
                      ? tr(context, '导入中…', 'Adding…')
                      : tr(context, '导入', 'Import'),
                  filled: true,
                  onTap: _busy ? null : _import,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
