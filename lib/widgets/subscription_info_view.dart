import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';

const _expireGap = 12.0;

class SubscriptionInfoView extends StatelessWidget {
  final SubscriptionInfo? subscriptionInfo;

  const SubscriptionInfoView({super.key, this.subscriptionInfo});

  double _textWidth(BuildContext context, String text, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final info = subscriptionInfo;
    if (info == null || info.total == 0) {
      return const SizedBox.shrink();
    }
    final use = info.upload.toDouble() + info.download.toDouble();
    final total = info.total;
    final progress = info.usage;

    final useShow = use.traffic.show;
    final totalShow = total.traffic.show;
    final expireShow =
        info.expireDate?.show ?? context.appLocalizations.infiniteTime;
    final valueStyle = AppTextStyle.subheadline
        .of(context, emphasized: true)
        .copyWith(color: context.colorScheme.onSurfaceVariant);
    final metaStyle = AppTextStyle.footnote.of(context).toLight;
    final trafficLabel = '$useShow / $totalShow';
    final trafficText = Text(
      trafficLabel,
      style: valueStyle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final expireText = Text(
      expireShow,
      style: metaStyle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final showExpire =
                _textWidth(context, trafficLabel, valueStyle) +
                    _expireGap +
                    _textWidth(context, expireShow, metaStyle) <=
                constraints.maxWidth;
            return Row(
              children: [
                Expanded(child: trafficText),
                if (showExpire) ...[
                  const SizedBox(width: _expireGap),
                  expireText,
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          minHeight: 4,
          value: progress,
          backgroundColor: context.colorScheme.primary.opacity15,
        ),
      ],
    );
  }
}

class SubscriptionInfoDetailView extends StatelessWidget {
  final SubscriptionInfo subscriptionInfo;

  const SubscriptionInfoDetailView({super.key, required this.subscriptionInfo});

  Widget _buildItem({String? label, required String value}) {
    return DecorationListItem(
      title: Text(label ?? value),
      subtitle: label == null ? null : TooltipLabel(value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final used =
        subscriptionInfo.upload.toDouble() + subscriptionInfo.download.toDouble();
    final expire =
        subscriptionInfo.expireDate?.show ?? appLocalizations.infiniteTime;
    return SelectionArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          generateSection(
            title: appLocalizations.trafficUsage,
            items: [
              _buildItem(
                label: appLocalizations.usedTraffic,
                value: used.traffic.show,
              ),
              _buildItem(
                label: appLocalizations.totalTraffic,
                value: subscriptionInfo.total.traffic.show,
              ),
            ],
          ),
          generateSection(
            title: appLocalizations.expireTime,
            items: [_buildItem(value: expire)],
          ),
        ],
      ),
    );
  }
}
