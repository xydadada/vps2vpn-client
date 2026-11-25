// vps2vpn: a note to the admin, with the check results and the latest log,
// masked before the user sees what will go.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/diagnose.dart';
import 'package:fl_clash/vps2vpn/home.dart' show mainGroup;
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart'
    show AlertDialog, InputDecoration, TextButton, TextField;
import 'package:url_launcher/url_launcher.dart';

final vpsIssuesPage = Uri.parse(
  'https://github.com/$vpsReleaseRepository/issues/new',
);

final _subPath = RegExp(r'/s/[A-Za-z0-9_-]{8,}');
final _secretPair = RegExp(
  r'''(["']?(?:password|passwd|pass|token|secret|uuid|auth|psk|private[-_]key|public[-_]key|short[-_]id)["']?\s*[:=]\s*)(["']?)[^\s"',}&]+''',
  caseSensitive: false,
);
final _uuid = RegExp(
  r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b',
);
final _ipv4 = RegExp(r'\b(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}\b');
final _ipv6 = RegExp(r'[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}');
final _longToken = RegExp(
  r'(?<![\w+/=-])(?=[\w+/=-]*\d)(?=[\w+/=-]*[A-Za-z])[\w+/=-]{24,}',
);

/// Subscription tokens, passwords and keys, UUIDs, and the last half of
/// every IP address; the panel masks again, but nothing leaves unmasked.
String vpsMaskSecrets(String text) {
  var s = text.replaceAll(_subPath, '/s/***');
  s = s.replaceAllMapped(_secretPair, (m) => '${m[1]}${m[2]}***');
  s = s.replaceAll(_uuid, '<uuid>');
  s = s.replaceAllMapped(_ipv4, (m) => '${m[1]}.${m[2]}.x.x');
  s = s.replaceAllMapped(_ipv6, (m) {
    final found = m[0]!;
    final address = InternetAddress.tryParse(found);
    if (address == null || address.type != InternetAddressType.IPv6) {
      return found;
    }
    return '${found.split(':').take(2).join(':')}:x:x';
  });
  return s.replaceAll(_longToken, '<redacted>');
}

typedef VpsFeedbackStep = ({String id, bool ok, String detail});

const _maxText = 4000;
const _maxLogBytes = 60 * 1024;

String _tailBytes(String text, int maxBytes) {
  if (utf8.encode(text).length <= maxBytes) return text;
  var cut = text.length - maxBytes;
  while (cut < text.length &&
      utf8.encode(text.substring(cut)).length > maxBytes) {
    cut += 1024;
  }
  final tail = text.substring(cut.clamp(0, text.length));
  final line = tail.indexOf('\n');
  return line < 0 ? tail : tail.substring(line + 1);
}

Map<String, Object?> vpsFeedbackBody({
  required String text,
  required Map<String, String> client,
  List<VpsFeedbackStep> steps = const [],
  String log = '',
}) {
  final note = vpsMaskSecrets(text.trim());
  final masked = _tailBytes(vpsMaskSecrets(log.trim()), _maxLogBytes);
  return {
    if (note.isNotEmpty)
      'text': note.length > _maxText ? note.substring(0, _maxText) : note,
    if (steps.isNotEmpty)
      'diagnosis': {
        'steps': [
          for (final step in steps)
            {
              'id': step.id,
              'ok': step.ok,
              'detail': vpsMaskSecrets(step.detail),
            },
        ],
      },
    if (masked.isNotEmpty) 'log': masked,
    'client': {
      for (final MapEntry(:key, :value) in client.entries)
        if (RegExp(r'^[a-z_]+$').hasMatch(key))
          key: value.length > 64 ? value.substring(0, 64) : value,
    },
  };
}

Map<String, String> vpsFeedbackClient() => {
  'version': globalState.packageInfo.version,
  'platform': switch (Platform.operatingSystem) {
    'windows' ||
    'android' ||
    'macos' ||
    'linux' ||
    'ios' => Platform.operatingSystem,
    _ => 'web',
  },
  'os': vpsMaskSecrets(Platform.operatingSystemVersion),
  'core': 'mihomo',
};

String _clockOf(DateTime at) =>
    '${'${at.hour}'.padLeft(2, '0')}:${'${at.minute}'.padLeft(2, '0')}';

List<VpsFeedbackStep> vpsFeedbackSteps(WidgetRef ref) {
  final on = ref.read(isStartProvider) && !ref.read(suspendProvider);
  final steps = <VpsFeedbackStep>[(id: 'connected', ok: on, detail: '')];
  final group = mainGroup(ref.read(currentGroupsStateProvider).value);
  if (on && group != null) {
    final delay = ref.read(
      delayProvider(proxyName: group.name, testUrl: group.testUrl),
    );
    if (delay != null && delay != 0) {
      steps.add((
        id: 'line',
        ok: delay > 0,
        detail: delay > 0 ? '$delay ms' : 'timeout',
      ));
    }
  }
  final last = vpsLastDiagnosis.value;
  if (last != null) {
    for (final MapEntry(key: leg, value: state) in last.legs.entries) {
      if (state != VpsLegState.ok && state != VpsLegState.failed) continue;
      steps.add((
        id: leg.name,
        ok: state == VpsLegState.ok,
        detail: 'checked ${_clockOf(last.at)}',
      ));
    }
  }
  return steps;
}

String vpsFeedbackLog(WidgetRef ref, {int lines = 200}) {
  final logs = ref.read(logsProvider).list;
  return [
    for (final log in logs.skip(logs.length > lines ? logs.length - lines : 0))
      '${log.dateTime} [${log.logLevel.name}] ${log.payload}',
  ].join('\n');
}

/// The note as text, for another provider's support or for an issue.
String vpsFeedbackText(Map<String, Object?> body) {
  final out = StringBuffer();
  if (body['text'] case final String text) out.writeln(text);
  out.writeln('client: ${jsonEncode(body['client'])}');
  if (body['diagnosis'] case {'steps': final List steps}) {
    for (final step in steps.cast<Map>()) {
      out.writeln(
        '${step['ok'] == true ? 'ok  ' : 'FAIL'} ${step['id']} ${step['detail']}',
      );
    }
  }
  if (body['log'] case final String log) {
    out
      ..writeln('--- log ---')
      ..writeln(log);
  }
  return out.toString().trim();
}

class VpsFeedbackDraft {
  const VpsFeedbackDraft({
    required this.base,
    required this.body,
    required this.at,
  });

  final String base;
  final Map<String, Object?> body;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'base': base,
    'body': body,
    'at': at.millisecondsSinceEpoch,
  };

  static VpsFeedbackDraft? fromJson(Object? json) => switch (json) {
    {'base': final String base, 'body': final Map body, 'at': final int at} =>
      VpsFeedbackDraft(
        base: base,
        body: body.cast<String, Object?>(),
        at: DateTime.fromMillisecondsSinceEpoch(at),
      ),
    _ => null,
  };
}

typedef VpsFeedbackPost =
    Future<VpsFeedbackAnswer> Function(Uri base, Map<String, Object?> body);

Future<String?> Function() vpsFeedbackLoad = () =>
    preferences.getVpsFeedback('Outbox');
Future<void> Function(String) vpsFeedbackSave = (value) =>
    preferences.setVpsFeedback('Outbox', value);

/// Notes that could not reach the panel, kept until it answers: what the
/// user wrote is never lost to a failed send.
class VpsFeedbackOutbox extends Notifier<List<VpsFeedbackDraft>> {
  var _loaded = false;
  var _flushing = false;

  @override
  List<VpsFeedbackDraft> build() => const [];

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await vpsFeedbackLoad();
      if (raw == null || !ref.mounted) return;
      final list = jsonDecode(raw);
      if (list is! List) return;
      state = [
        ...state,
        for (final item in list) ?VpsFeedbackDraft.fromJson(item),
      ];
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      await vpsFeedbackSave(jsonEncode([for (final d in state) d.toJson()]));
    } catch (_) {}
  }

  Future<VpsFeedbackAnswer> send(
    Uri base,
    Map<String, Object?> body, [
    VpsFeedbackPost? post,
  ]) async {
    await _load();
    final answer = await (post ?? _postFor(ref))(base, body);
    if (answer.outcome == VpsFeedbackOutcome.unreachable) {
      state = [
        ...state,
        VpsFeedbackDraft(base: '$base', body: body, at: DateTime.now()),
      ];
      await _save();
    }
    return answer;
  }

  /// Sends what waits, oldest first, stopping at the first that still cannot
  /// go; [told] hears each one's fate.
  Future<List<VpsFeedbackItem>?> replies(Uri base) async {
    final route = await vpsPanelRoute(ref, base);
    return vpsFetchFeedback(
      base,
      proxyPort: route.port,
      proxyAuth: route.auth,
      pinnedSha256: route.pins,
    );
  }

  Future<void> flush(
    void Function(VpsFeedbackDraft draft, VpsFeedbackAnswer answer) told, [
    VpsFeedbackPost? post,
  ]) async {
    final postOne = post ?? _postFor(ref);
    await _load();
    if (_flushing || state.isEmpty) return;
    _flushing = true;
    try {
      while (state.isNotEmpty && ref.mounted) {
        final draft = state.first;
        final answer = await postOne(Uri.parse(draft.base), draft.body);
        if (answer.outcome == VpsFeedbackOutcome.unreachable ||
            answer.outcome == VpsFeedbackOutcome.rateLimited) {
          return;
        }
        state = state.skip(1).toList();
        await _save();
        told(draft, answer);
      }
    } finally {
      _flushing = false;
    }
  }
}

final vpsFeedbackOutboxProvider =
    NotifierProvider<VpsFeedbackOutbox, List<VpsFeedbackDraft>>(
      VpsFeedbackOutbox.new,
    );

VpsFeedbackPost _postFor(Ref ref) => (base, body) async {
  final route = await vpsPanelRoute(ref, base);
  return vpsPostFeedback(
    base,
    body,
    proxyPort: route.port,
    proxyAuth: route.auth,
    pinnedSha256: route.pins,
  );
};

int? _toldUnread;

/// Once the panel answers, what waits goes out; a new reply is told once.
final vpsFeedbackSyncProvider = Provider.autoDispose<void>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  final member = ref.watch(vpsMemberProvider).value?.member;
  if (member == null || !member.feedback) return;
  unawaited(
    ref.read(vpsFeedbackOutboxProvider.notifier).flush((draft, answer) {
      final context = globalState.navigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      dialogs.showBanner(
        answer.outcome == VpsFeedbackOutcome.sent
            ? tr(
                context,
                '网络恢复了，之前保存的反馈已发送',
                'Back online: the note you saved has been sent',
              )
            : tr(
                context,
                '之前保存的反馈没能发送（${_why(context, answer)}），可以在「我的」→「反馈问题」里复制后发给服务提供者',
                'The note you saved could not be sent '
                    '(${_why(context, answer)}); copy it from Me > '
                    'Feedback and send it to your provider',
              ),
      );
    }),
  );
  final unread = member.feedbackUnread;
  unawaited(() async {
    _toldUnread ??=
        int.tryParse(await preferences.getVpsFeedback('ToldUnread') ?? '') ?? 0;
    if (unread == _toldUnread) return;
    final more = unread > _toldUnread!;
    _toldUnread = unread;
    await preferences.setVpsFeedback('ToldUnread', '$unread');
    if (!more) return;
    final context = globalState.navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    dialogs.showBanner(
      tr(
        context,
        '管理员回复了你的反馈，到「我的」→「反馈问题」查看',
        'The admin answered your note; see Me > Feedback',
      ),
    );
  }());
});

String _why(BuildContext context, VpsFeedbackAnswer answer) =>
    switch (answer.outcome) {
      VpsFeedbackOutcome.tooLarge => tr(context, '内容太大', 'too large'),
      VpsFeedbackOutcome.featureOff => tr(
        context,
        '服务器没有开反馈',
        'feedback is off on the server',
      ),
      VpsFeedbackOutcome.linkWrong => tr(
        context,
        '订阅链接已失效',
        'the subscription link no longer works',
      ),
      _ => tr(context, '服务器不接受这条内容', 'the server refused it'),
    };

bool vpsFeedbackOpen(WidgetRef ref) {
  final url = ref.read(currentProfileProvider)?.url ?? '';
  final member = ref.read(vpsMemberProvider).value?.member;
  return vpsApiBase(url) != null && (member == null || member.feedback);
}

Future<void> vpsShowFeedback(WidgetRef ref) =>
    dialogs.showCommonDialog<void>(child: const _FeedbackDialog());

class _FeedbackDialog extends ConsumerStatefulWidget {
  const _FeedbackDialog();

  @override
  ConsumerState<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends ConsumerState<_FeedbackDialog> {
  final _text = TextEditingController();
  var _withSteps = true;
  var _withLog = true;
  var _preview = false;
  var _sending = false;
  var _off = false;
  String? _error;
  Future<List<VpsFeedbackItem>?>? _replies;

  Uri? get _base => vpsApiBase(ref.read(currentProfileProvider)?.url ?? '');

  @override
  void initState() {
    super.initState();
    _off = !vpsFeedbackOpen(ref);
    final base = _base;
    if (!_off && base != null) {
      _replies = () async {
        final items = await ref
            .read(vpsFeedbackOutboxProvider.notifier)
            .replies(base);
        if (mounted && items != null) ref.invalidate(vpsMemberProvider);
        return items;
      }();
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Map<String, Object?> _body() => vpsFeedbackBody(
    text: _text.text,
    client: vpsFeedbackClient(),
    steps: _withSteps ? vpsFeedbackSteps(ref) : const [],
    log: _withLog ? vpsFeedbackLog(ref) : '',
  );

  bool get _empty =>
      _text.text.trim().isEmpty &&
      !_withSteps &&
      (!_withLog || ref.read(logsProvider).list.isEmpty);

  Future<void> _send() async {
    final base = _base;
    if (base == null || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final answer = await ref
        .read(vpsFeedbackOutboxProvider.notifier)
        .send(base, _body());
    if (!mounted) return;
    setState(() => _sending = false);
    switch (answer.outcome) {
      case VpsFeedbackOutcome.sent:
        Navigator.of(context).pop();
        dialogs.showBanner(
          tr(
            context,
            '已发送。管理员回复后会提醒你',
            'Sent. You will hear when the admin answers',
          ),
        );
      case VpsFeedbackOutcome.unreachable:
        Navigator.of(context).pop();
        dialogs.showBanner(
          tr(
            context,
            '现在连不上服务器，反馈已保存，网络恢复后自动发送',
            'The server is out of reach; your note is saved and goes out '
                'once the network is back',
          ),
        );
      case VpsFeedbackOutcome.rateLimited:
        final minutes = ((answer.retryAfter?.inSeconds ?? 120) / 60).ceil();
        setState(
          () => _error = tr(
            context,
            '发得太频繁了，$minutes 分钟后可再发，写的内容还在',
            'Too many notes; try again in $minutes min. What you wrote is kept',
          ),
        );
      case VpsFeedbackOutcome.featureOff:
        setState(() {
          _off = true;
          _error = tr(
            context,
            '服务器没有开反馈，可以复制诊断信息发给服务提供者',
            'Feedback is off on the server; copy the details for your provider',
          );
        });
      case VpsFeedbackOutcome.tooLarge:
        setState(
          () => _error = tr(
            context,
            '内容太大，关掉"附带最近日志"再发',
            'Too large; turn off the log and send again',
          ),
        );
      case VpsFeedbackOutcome.linkWrong:
        setState(() {
          _off = true;
          _error = tr(
            context,
            '订阅链接已失效，发不出去；可以复制诊断信息发给服务提供者',
            'The subscription link no longer works; copy the details for '
                'your provider',
          );
        });
      case VpsFeedbackOutcome.rejected:
        setState(
          () => _error = tr(
            context,
            '服务器不接受这条内容，写几句话再发',
            'The server refused it; write a few words and send again',
          ),
        );
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: vpsFeedbackText(_body())));
    if (!mounted) return;
    dialogs.showBanner(
      tr(
        context,
        '诊断信息已复制（已打码），发给你的服务提供者',
        'Details copied (masked); send them to your provider',
      ),
    );
  }

  Widget _check(
    VpsPalette p,
    String label,
    bool value,
    ValueChanged<bool> on,
  ) => Row(
    children: [
      Expanded(
        child: Text(label, style: vpsText(p, type: VpsType.subhead)),
      ),
      VpsSwitch(value: value, onChanged: on),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final p = VpsPalette.of(context);
    return AlertDialog(
      title: tr(context, '反馈问题', 'Feedback'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr(context, '关闭', 'Close')),
        ),
        if (_off) ...[
          TextButton(
            onPressed: () => unawaited(
              launchUrl(vpsIssuesPage, mode: LaunchMode.externalApplication),
            ),
            child: Text(tr(context, '客户端 bug', 'Client bug')),
          ),
          TextButton(
            onPressed: _copy,
            child: Text(tr(context, '复制诊断信息', 'Copy details')),
          ),
        ] else
          TextButton(
            onPressed: _sending || _empty ? null : _send,
            child: Text(
              _sending
                  ? tr(context, '发送中…', 'Sending…')
                  : tr(context, '发送', 'Send'),
            ),
          ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _off
                    ? tr(
                        context,
                        '这个订阅的服务器不收反馈。复制诊断信息（已打码）发给你的服务提供者；只有客户端本身的 bug 才到 GitHub 提。',
                        "This subscription's server takes no notes. Copy the "
                            'details (masked) for your provider; only bugs in '
                            'the client itself belong on GitHub.',
                      )
                    : tr(
                        context,
                        '写下遇到的问题，管理员会看到。发送前链接、密码、完整 IP 都会打码，下方可以看到要发送的全部内容。',
                        'Say what went wrong; the admin will see it. Links, '
                            'passwords and full IPs are masked first; '
                            'everything that goes is shown below.',
                      ),
                style: vpsText(
                  p,
                  type: VpsType.subhead,
                  color: p.soft,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _text,
                minLines: 3,
                maxLines: 6,
                maxLength: _maxText,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: tr(
                    context,
                    '例如：今晚 9 点后一直连不上，换节点也不行',
                    'E.g. no connection since 9 pm, other nodes too',
                  ),
                  errorText: _error,
                  errorMaxLines: 3,
                ),
              ),
              _check(
                p,
                tr(context, '附带检测结果', 'Include the check results'),
                _withSteps,
                (v) => setState(() => _withSteps = v),
              ),
              _check(
                p,
                tr(context, '附带最近日志', 'Include the latest log'),
                _withLog,
                (v) => setState(() => _withLog = v),
              ),
              VpsPressable(
                onTap: () => setState(() => _preview = !_preview),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _preview
                        ? tr(context, '收起要发送的内容', 'Hide what goes')
                        : tr(context, '查看要发送的内容', 'Show what goes'),
                    style: vpsText(p, type: VpsType.subhead, color: p.accent),
                  ),
                ),
              ),
              if (_preview)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: Text(
                      vpsFeedbackText(_body()),
                      style: vpsText(
                        p,
                        type: VpsType.caption,
                        color: p.soft,
                        tabular: true,
                      ),
                    ),
                  ),
                ),
              if (_replies != null)
                FutureBuilder<List<VpsFeedbackItem>?>(
                  future: _replies,
                  builder: (context, snap) {
                    final items = snap.data ?? const [];
                    if (items.isEmpty) return const SizedBox.shrink();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 12),
                        Text(
                          tr(context, '最近的反馈', 'Recent notes'),
                          style: vpsText(
                            p,
                            type: VpsType.subhead,
                            weight: FontWeight.w600,
                          ),
                        ),
                        for (final item in items)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              item.answer.isEmpty
                                  ? '${item.text}\n${item.done ? tr(context, '已处理', 'Done') : tr(context, '等待回复', 'Waiting')}'
                                  : '${item.text}\n${tr(context, '回复', 'Answer')}：${item.answer}',
                              style: vpsText(
                                p,
                                type: VpsType.footnote,
                                color: item.answer.isEmpty ? p.soft : p.text,
                                height: 1.45,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

int _unread(WidgetRef ref) => ref.watch(
  vpsMemberProvider.select((s) => s.value?.member?.feedbackUnread ?? 0),
);

class VpsFeedbackNotice extends ConsumerWidget {
  const VpsFeedbackNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (_unread(ref) == 0) return const SizedBox.shrink();
    final p = VpsPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: VpsCard(
        highlight: true,
        padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
        child: Row(
          children: [
            VpsIconView(VpsIcon.info, size: 19, color: p.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                tr(context, '管理员回复了你的反馈', 'The admin answered your note'),
                style: vpsText(p, type: VpsType.body, weight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            VpsButton(
              label: tr(context, '查看', 'View'),
              filled: true,
              onTap: () => unawaited(vpsShowFeedback(ref)),
            ),
          ],
        ),
      ),
    );
  }
}

class VpsFeedbackRow extends ConsumerWidget {
  const VpsFeedbackRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = VpsPalette.of(context);
    final unread = _unread(ref);
    final waiting = ref.watch(vpsFeedbackOutboxProvider).length;
    return VpsRow(
      icon: VpsIcon.info,
      title: tr(context, '反馈问题', 'Feedback'),
      subtitle: waiting > 0
          ? tr(
              context,
              '$waiting 条等网络恢复后发送',
              '$waiting waiting for the network',
            )
          : unread > 0
          ? tr(context, '管理员回复了你', 'The admin answered you')
          : tr(
              context,
              '把问题和检测结果发给管理员',
              'Send the problem and the check results to the admin',
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (unread > 0)
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: p.bad, shape: BoxShape.circle),
            ),
          const SizedBox(width: 8),
          VpsIconView(VpsIcon.chevron, size: 16, color: p.muted),
        ],
      ),
      onTap: () => unawaited(vpsShowFeedback(ref)),
    );
  }
}
