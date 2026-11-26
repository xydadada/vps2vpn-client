// vps2vpn "Website test": the user's own list of sites, each timed through
// the node in use.

import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/common/system.dart' show system;
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/home.dart' show mainGroup;
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef VpsSite = ({String name, String url});

const vpsDefaultSites = <VpsSite>[
  (name: 'Apple', url: 'https://www.apple.com'),
  (name: 'GitHub', url: 'https://github.com'),
  (name: 'Google', url: 'https://www.google.com'),
  (name: 'YouTube', url: 'https://www.youtube.com'),
];

/// A site from what the user typed: a bare host gets https://, the name is
/// the host without www. Null when it is not a web address.
VpsSite? vpsSiteFrom(String input) {
  var text = input.trim();
  if (text.isEmpty || text.contains(RegExp(r'\s'))) return null;
  if (!text.contains('://')) text = 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri == null ||
      !(uri.scheme == 'http' || uri.scheme == 'https') ||
      !uri.host.contains('.')) {
    return null;
  }
  return (name: uri.host.replaceFirst(RegExp('^www\\.'), ''), url: text);
}

List<VpsSite> _decode(List<String>? stored) {
  if (stored == null) return vpsDefaultSites;
  return [
    for (final line in stored)
      if (line.indexOf('|') case final i when i > 0)
        (name: line.substring(0, i), url: line.substring(i + 1)),
  ];
}

class VpsSiteTestCard extends ConsumerStatefulWidget {
  const VpsSiteTestCard({super.key});

  @override
  ConsumerState<VpsSiteTestCard> createState() => _VpsSiteTestCardState();
}

class _VpsSiteTestCardState extends ConsumerState<VpsSiteTestCard> {
  final _input = TextEditingController();
  List<VpsSite> _sites = vpsDefaultSites;
  String? _error;
  bool _testing = false;
  bool _edited = false;

  @override
  void initState() {
    super.initState();
    preferences.getVpsSites().then((stored) {
      if (mounted && !_edited) setState(() => _sites = _decode(stored));
    });
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _save(List<VpsSite> sites) {
    _edited = true;
    setState(() => _sites = sites);
    preferences.setVpsSites([for (final s in sites) '${s.name}|${s.url}']);
  }

  void _add() {
    final site = vpsSiteFrom(_input.text);
    if (site == null) {
      setState(
        () => _error = tr(
          context,
          '这不是网址，例如 github.com',
          'Not a web address; for example github.com',
        ),
      );
      return;
    }
    _input.clear();
    _error = null;
    _save([..._sites.where((s) => s.url != site.url), site]);
  }

  /// The selection of the main group, so the sites are timed through the
  /// node the user is on.
  Proxy? _through() {
    final group = mainGroup(ref.read(currentGroupsStateProvider).value);
    if (group == null) return null;
    final name = ref.read(selectedProxyNameProvider(group.name)) ?? group.now;
    return group.all.where((p) => p.name == name).firstOrNull ??
        group.all.where((p) => p.name == group.now).firstOrNull;
  }

  Future<void> _testAll() async {
    final proxy = _through();
    if (proxy == null || _testing) return;
    setState(() => _testing = true);
    try {
      final action = ref.read(proxiesActionProvider.notifier);
      final sites = [..._sites];
      for (var i = 0; i < sites.length && mounted; i += 4) {
        await Future.wait([
          for (final site in sites.skip(i).take(4))
            action.delayTest([proxy], site.url),
        ]);
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final on = ref.watch(isStartProvider);
    final group = mainGroup(ref.watch(currentGroupsStateProvider).value);
    final selected = group == null
        ? null
        : ref.watch(selectedProxyNameProvider(group.name)) ?? group.now;
    final picked = group != null && group.all.any((p) => p.name == selected)
        ? selected
        : group?.now;
    return VpsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  on
                      ? tr(
                          context,
                          '经当前节点测这些网站的延迟',
                          'Latency to these sites through your node',
                        )
                      : tr(context, '连接后可以测试', 'Connect to test'),
                  style: vpsText(p, size: 13.5, color: p.soft),
                ),
              ),
              const SizedBox(width: 12),
              VpsButton(
                label: _testing
                    ? tr(context, '测试中…', 'Testing…')
                    : tr(context, '全部测试', 'Test all'),
                icon: VpsIcon.bolt,
                onTap: !on || _testing || picked == null ? null : _testAll,
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final site in _sites)
            _SiteRow(
              name: site.name,
              delay: picked == null
                  ? null
                  : _Delay(proxyName: picked, url: site.url),
              onRemove: () =>
                  _save([..._sites.where((s) => s.url != site.url)]),
            ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: VpsField(
                  controller: _input,
                  keyboardType: TextInputType.url,
                  onSubmitted: (_) => _add(),
                  hint: tr(
                    context,
                    '添加网站，例如 github.com',
                    'Add a site, e.g. github.com',
                  ),
                  error: _error,
                ),
              ),
              const SizedBox(width: 10),
              VpsButton(
                label: tr(context, '添加', 'Add'),
                icon: VpsIcon.plus,
                onTap: _add,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A site; its remove x shows while the pointer is on the row, and always
/// where there is no pointer.
class _SiteRow extends StatefulWidget {
  const _SiteRow({
    required this.name,
    required this.delay,
    required this.onRemove,
  });

  final String name;
  final Widget? delay;
  final VoidCallback onRemove;

  @override
  State<_SiteRow> createState() => _SiteRowState();
}

class _SiteRowState extends State<_SiteRow> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final shown = _hover || !system.isDesktop;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: vpsText(p, size: 14, weight: FontWeight.w500),
              ),
            ),
            ?widget.delay,
            const SizedBox(width: 4),
            ExcludeFocus(
              excluding: !shown,
              child: IgnorePointer(
                ignoring: !shown,
                child: AnimatedOpacity(
                  opacity: shown ? 1 : 0,
                  duration: VpsMotion.fast,
                  child: VpsPressable(
                    onTap: widget.onRemove,
                    semanticLabel: tr(context, '删除', 'Remove'),
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: Center(
                        child: VpsIconView(
                          VpsIcon.close,
                          size: 14,
                          color: p.soft,
                        ),
                      ),
                    ),
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

class _Delay extends ConsumerWidget {
  const _Delay({required this.proxyName, required this.url});

  final String proxyName;
  final String url;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = VpsPalette.of(context);
    final d = ref.watch(delayProvider(proxyName: proxyName, testUrl: url));
    return switch (d) {
      null => VpsChip(label: tr(context, '未测', 'Not tested'), color: p.muted),
      0 => VpsChip(label: tr(context, '测试中…', 'Testing…'), color: p.muted),
      < 0 => VpsChip(label: tr(context, '打不开', 'Fails'), color: p.bad),
      final ms => VpsChip(
        label: '$ms ms',
        color: ms < 300 ? p.good : (ms < 800 ? p.warn : p.bad),
      ),
    };
  }
}
