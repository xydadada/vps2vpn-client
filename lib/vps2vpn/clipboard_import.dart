import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' show InputDecoration, TextField;

enum VpsImportResult { added, failed }

/// The subscription link on the clipboard. A plain URL, a share link, or a
/// clash://install-config?url=… wrapper all come down to one link; [strict]
/// keeps any provider's subscription, so an ordinary web address is none.
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
  return !strict || vpsLooksLikeSubscription(text!.trim(), link) ? link : null;
}

final _subscriptionPath = RegExp(
  r'(^|/)(s|sub|subs|subscribe|subscription|link|clash|getsub|api/v\d+/client)(/|$)'
  r'|\.ya?ml$|\.conf$',
  caseSensitive: false,
);
const _subscriptionQuery = {
  'token',
  'sub',
  'subscribe',
  'clash',
  'target',
  'flag',
  'mu',
};

bool vpsLooksLikeSubscription(String copied, String link) {
  if (vpsApiBase(link) != null || copied.isShareLink) return true;
  if (linkSchemes.contains(Uri.tryParse(copied)?.scheme)) return true;
  final uri = Uri.tryParse(link);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return false;
  }
  return _subscriptionPath.hasMatch(uri.path) ||
      uri.queryParameters.keys.any(
        (k) => _subscriptionQuery.contains(k.toLowerCase()),
      );
}

Future<VpsImportResult> vpsImportLink(WidgetRef ref, String link) async {
  final before = ref.read(profilesProvider).length;
  try {
    await ref.read(profilesActionProvider.notifier).addProfileFromLink(link);
  } catch (_) {
    return VpsImportResult.failed;
  }
  return ref.read(profilesProvider).length > before
      ? VpsImportResult.added
      : VpsImportResult.failed;
}

String? vpsImportNote(
  BuildContext context,
  VpsImportResult result,
) => switch (result) {
  VpsImportResult.added => null,
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

/// Why [text] cannot be imported, or null when it holds one link.
String? vpsLinkProblem(BuildContext context, String text) {
  final value = text.trim();
  if (value.isEmpty) {
    return tr(
      context,
      '请先粘贴或输入订阅链接。',
      'Paste or type your subscription link first.',
    );
  }
  if (value.contains(RegExp(r'\s'))) {
    return tr(
      context,
      '一次只能导入一个链接，框里有空格或换行。请只留下一个链接。',
      'One link at a time: there is a space or a line break. Keep just one link.',
    );
  }
  if (profileUrlFromQrCodes([value]) == null) {
    return value.contains('://')
        ? tr(
            context,
            '这不是订阅链接。请检查是否复制完整。',
            'This is not a subscription link. Check it was copied in full.',
          )
        : tr(
            context,
            '链接要以 http:// 或 https:// 开头。',
            'A link starts with http:// or https://.',
          );
  }
  return null;
}

/// A box to paste or type the subscription link into, with Import and
/// "Paste from clipboard" (which only fills the box). Long links wrap, so
/// the whole link stays visible.
class VpsImportField extends ConsumerStatefulWidget {
  const VpsImportField({
    super.key,
    this.onAdded,
    this.withFile = false,
    this.replace,
  });

  final VoidCallback? onAdded;
  final bool withFile;

  /// Replaces a subscription's link; answers why it failed, or null.
  final Future<String?> Function(String link)? replace;

  @override
  ConsumerState<VpsImportField> createState() => VpsImportFieldState();
}

class VpsImportFieldState extends ConsumerState<VpsImportField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Imports what is in the box; an empty box is filled from the clipboard
  /// first, for the user to check and confirm.
  Future<void> submitOrFill() async {
    if (_controller.text.trim().isEmpty) {
      await _paste();
      _focus.requestFocus();
      return;
    }
    await _import();
  }

  Future<void> _paste() async {
    final link = await vpsClipboardLink();
    if (!mounted) return;
    setState(() {
      if (link == null) {
        _error = tr(
          context,
          '剪贴板里没有订阅链接。也可以直接在框里输入。',
          'No subscription link on the clipboard. You can also type it in the box.',
        );
      } else {
        _controller.text = link;
        _error = null;
      }
    });
  }

  Future<void> _import() async {
    if (_busy) return;
    final problem = vpsLinkProblem(context, _controller.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final link = vpsSubscriptionLink(
      profileUrlFromQrCodes([_controller.text.trim()])!,
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    final String? error;
    if (widget.replace case final replace?) {
      error = await replace(link);
    } else {
      final result = await vpsImportLink(ref, link);
      error = mounted ? vpsImportNote(context, result) : null;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      if (error == null) _controller.clear();
    });
    if (error == null) widget.onAdded?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _controller,
          focusNode: _focus,
          minLines: 1,
          maxLines: 4,
          keyboardType: TextInputType.url,
          autocorrect: false,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => _import(),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          decoration: InputDecoration(
            hintText: tr(
              context,
              '粘贴或输入订阅链接',
              'Paste or type your subscription link',
            ),
            errorText: _error,
            errorMaxLines: 3,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            VpsButton(
              label: widget.replace != null
                  ? (_busy
                        ? tr(context, '替换中…', 'Replacing…')
                        : tr(context, '替换', 'Replace'))
                  : _busy
                  ? tr(context, '导入中…', 'Adding…')
                  : tr(context, '导入', 'Import'),
              filled: true,
              onTap: _busy ? null : _import,
            ),
            VpsButton(
              label: tr(context, '从剪贴板粘贴', 'Paste from clipboard'),
              icon: VpsIcon.paste,
              onTap: _busy ? null : _paste,
            ),
            if (widget.withFile && widget.replace == null)
              VpsButton(
                label: tr(context, '本地文件', 'Local file'),
                icon: VpsIcon.file,
                onTap: () => ref
                    .read(profilesActionProvider.notifier)
                    .addProfileFormFile(),
              ),
          ],
        ),
      ],
    );
  }
}
