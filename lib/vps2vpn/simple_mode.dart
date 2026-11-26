// vps2vpn: simple mode (default) and advanced mode.
//
// Simple mode shows a few pages with plain words; advanced mode shows every
// FlClash page unchanged. The switch is AppSettingProps.advancedMode.
// Kept in its own file so upstream FlClash changes merge with little conflict.

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/about.dart';
import 'package:fl_clash/views/profiles/profiles.dart';
import 'package:fl_clash/views/theme.dart';
import 'package:fl_clash/widgets/widgets.dart';

import 'flags.dart';
import 'kit.dart' show VpsPalette;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

export 'flags.dart';

/// An alert's default action in simple mode's accent with white text, where
/// FlClash's tonal primary puts dark text on pale coral.
Widget vpsDressAlert(BuildContext context, Widget child) {
  if (vps2vpnAdvancedMode || vps2vpnUpstreamUi) return child;
  final p = VpsPalette.of(context);
  final theme = Theme.of(context);
  return Theme(
    data: theme.copyWith(
      // Alerts sit on the cards' own surface, not the seed's tinted one.
      colorScheme: theme.colorScheme.copyWith(
        primary: p.accent,
        onPrimary: p.accentInk,
        surfaceBright: p.card,
        surfaceContainer: p.dark ? theme.colorScheme.surfaceContainer : p.track,
        surfaceContainerHigh: p.dark
            ? p.card
            : theme.colorScheme.surfaceContainerHigh,
        surfaceContainerHighest: p.dark ? p.thumb : p.track,
      ),
    ),
    child: child,
  );
}

/// "Outbound mode" in advanced mode, "How you go online" in simple mode.
String outboundModeTitle(BuildContext context) =>
    vps2vpnAdvancedMode || vps2vpnUpstreamUi
    ? context.appLocalizations.outboundMode
    : context.appLocalizations.vRouting;

/// The simple-mode navigation: Home, Servers, Me.
List<NavigationItem> simpleNavigationItems({
  required bool hasProxies,
  required WidgetBuilder dashboard,
  required WidgetBuilder proxies,
}) {
  return [
    NavigationItem(
      glyph: AppGlyphs.dashboard,
      label: PageLabel.dashboard,
      builder: dashboard,
    ),
    NavigationItem(
      glyph: AppGlyphs.proxies,
      label: PageLabel.proxies,
      builder: proxies,
      modes: hasProxies
          ? [NavigationItemMode.mobile, NavigationItemMode.desktop]
          : [],
    ),
    NavigationItem(
      glyph: AppGlyphs.account,
      label: PageLabel.tools,
      builder: (_) => const MineView(),
    ),
  ];
}

/// The switch between simple and advanced mode, shown in both.
class AdvancedModeItem extends ConsumerWidget {
  const AdvancedModeItem({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final advancedMode = ref.watch(
      appSettingProvider.select((state) => state.advancedMode),
    );
    return ListItem.toggle(
      leading: const GlyphIcon(AppGlyphs.sliders),
      title: Text(context.appLocalizations.vAdvancedMode),
      subtitle: Text(context.appLocalizations.vAdvancedModeDesc),
      value: advancedMode,
      onChanged: (value) {
        vps2vpnAdvancedMode = value;
        ref
            .read(appSettingProvider.notifier)
            .update((state) => state.copyWith(advancedMode: value));
        if (!value && ref.read(patchClashConfigProvider).mode == Mode.direct) {
          ref.read(setupActionProvider.notifier).changeMode(Mode.rule);
        }
      },
    );
  }
}

/// "Me": subscriptions, the mode switch, language, theme, about.
class MineView extends ConsumerStatefulWidget {
  const MineView({super.key});

  @override
  ConsumerState<MineView> createState() => _MineViewState();
}

class _MineViewState extends ConsumerState<MineView> {
  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    _controller = sheetScrollController(context);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    final items = [
      generateSection(
        items: [
          ListItem.open(
            leading: const GlyphIcon(AppGlyphs.profiles),
            title: Text(l.vSubscriptions),
            widget: const ProfilesView(),
          ),
        ],
      ),
      generateSection(
        title: l.vSettings,
        items: [
          const AdvancedModeItem(),
          const _LocaleItem(),
          ListItem.open(
            leading: const GlyphIcon(AppGlyphs.paintbrush),
            title: Text(l.theme),
            widget: const ThemeView(),
          ),
        ],
      ),
      generateSection(
        title: l.other,
        items: [
          ListItem.open(
            leading: const GlyphIcon(AppGlyphs.info),
            title: Text(l.about),
            widget: const AboutView(),
          ),
        ],
      ),
    ];
    return Scaffold(
      title: l.vMine,
      body: PrismListView(
        key: toolsStoreKey,
        controller: _controller,
        itemCount: items.length,
        itemBuilder: (_, index) => items[index],
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: context.sectionsTopPadding,
          bottom: 20 + context.bottomInset,
        ),
      ),
    );
  }
}

class _LocaleItem extends ConsumerWidget {
  const _LocaleItem();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(
      appSettingProvider.select((state) => state.locale),
    );
    final currentLocale = getLocaleForString(locale);
    return ListItem<Locale?>.options(
      leading: const GlyphIcon(AppGlyphs.language),
      title: Text(context.appLocalizations.language),
      options: [null, ...AppLocalizations.supportedLocales],
      onChanged: (Locale? locale) {
        ref
            .read(appSettingProvider.notifier)
            .update((state) => state.copyWith(locale: locale?.toString()));
      },
      textBuilder: (locale) =>
          locale == null ? context.appLocalizations.defaultText : locale.label,
      value: currentLocale == null
          ? null
          : basicLocaleListResolution([
              currentLocale,
            ], AppLocalizations.supportedLocales),
    );
  }
}
