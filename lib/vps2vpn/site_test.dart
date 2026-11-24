// vps2vpn "Website test": the user's own list of sites, each timed through
// the node in use.

import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/home.dart' show mainGroup;
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' show InputDecoration, TextField;

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

  @override
  void initState() {
    super.initState();
    preferences.getVpsSites().then((stored) {
      if (mounted) setState(() => _sites = _decode(stored));
    });
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _save(List<VpsSite> sites) {
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
    return group.all.where((p) => p.name == name).firstOrNull;
  }

  Future<void> _testAll() async {
    final proxy = _through();
    if (proxy == null || _testing) return;
    setState(() => _testing = true);
    try {
      final action = ref.read(proxiesActionProvider.notifier);
      await Future.wait([
        for (final site in _sites) action.delayTest([proxy], site.url),
      ]);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    final on = ref.watch(isStartProvider);
    final group = mainGroup(ref.watch(currentGroupsStateProvider).value);
    final picked = group == null
        ? null
        : ref.watch(selectedProxyNameProvider(group.name)) ?? group.now;
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
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      site.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: vpsText(p, size: 14, weight: FontWeight.w500),
                    ),
                  ),
                  if (picked != null) _Delay(proxyName: picked, url: site.url),
                  const SizedBox(width: 10),
                  VpsPressable(
                    onTap: () =>
                        _save([..._sites.where((s) => s.url != site.url)]),
                    child: Text(
                      tr(context, '删除', 'Remove'),
                      style: vpsText(p, size: 12.5, color: p.muted),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: (_) => _add(),
                  decoration: InputDecoration(
                    hintText: tr(
                      context,
                      '添加网站，例如 github.com',
                      'Add a site, e.g. github.com',
                    ),
                    errorText: _error,
                  ),
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
