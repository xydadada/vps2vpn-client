// What a subscription's headers say besides its traffic: the provider's
// announcement and the links to the user's page and to support.

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/vps2vpn/kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

bool hasSubscriptionExtras(SubscriptionInfo? info) =>
    info != null &&
    (info.announce != null ||
        info.webPageUrl != null ||
        info.supportUrl != null);

/// The announcement and the link buttons of [info]; nothing when it has none.
class VpsSubscriptionExtras extends StatelessWidget {
  const VpsSubscriptionExtras({super.key, required this.info});

  final SubscriptionInfo? info;

  @override
  Widget build(BuildContext context) {
    final info = this.info;
    if (info == null || !hasSubscriptionExtras(info)) {
      return const SizedBox.shrink();
    }
    final p = VpsPalette.of(context);
    final appLocalizations = context.appLocalizations;
    final links = [
      if (info.webPageUrl case final url?)
        VpsButton(
          icon: VpsIcon.globe,
          label: appLocalizations.subscriptionWebPage,
          onTap: () => openSubscriptionLink(url),
        ),
      if (info.supportUrl case final url?)
        VpsButton(
          icon: VpsIcon.me,
          label: appLocalizations.subscriptionSupport,
          onTap: () => openSubscriptionLink(url),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (info.announce case final announce?)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: VpsIconView(VpsIcon.info, size: 16, color: p.warn),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Semantics(
                  label: appLocalizations.subscriptionAnnounce,
                  child: Text(
                    announce,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: vpsText(p, type: VpsType.subhead, height: 1.45),
                  ),
                ),
              ),
            ],
          ),
        if (info.announce != null && links.isNotEmpty)
          const SizedBox(height: 12),
        if (links.isNotEmpty) Wrap(spacing: 8, runSpacing: 8, children: links),
      ],
    );
  }
}

/// Overview card for the provider's announcement on the subscription in use.
class VpsSubscriptionNotice extends ConsumerWidget {
  const VpsSubscriptionNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(
      currentProfileProvider.select((profile) => profile?.subscriptionInfo),
    );
    if (info?.announce == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: VpsCard(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        child: VpsSubscriptionExtras(info: info),
      ),
    );
  }
}
