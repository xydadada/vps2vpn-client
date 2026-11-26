import 'dart:async';
import 'dart:io';

import 'package:fl_clash/bootstrap.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/window.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/manager/hotkey_manager.dart';
import 'package:fl_clash/manager/manager.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/vps2vpn/auto_update.dart';
import 'package:fl_clash/vps2vpn/kit.dart' show VpsAccentScope;
import 'package:fl_clash/vps2vpn/panel.dart'
    show vpsLinkSource, vpsSubscriptionLink;
import 'package:fl_clash/vps2vpn/screenshots.dart';
import 'package:fl_clash/vps2vpn/simple_mode.dart' show vpsDressAlert;
import 'package:fl_clash/vps2vpn/takeover.dart'
    show vpsAskTakeover, vpsNoteForeignProxy;
import 'package:fl_clash/vps2vpn/takeover_notice.dart' show vpsShowTakeoverAsk;
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_api/rust_api.dart' show NetworkState;

import 'pages/pages.dart';

Widget buildManagerStack({
  required bool isDesktop,
  required Future<void> Function(NetworkState state) onConnectivityChanged,
  Stream<ProcessSignal>? terminateSignals,
  required Widget child,
}) {
  final platformApp = isDesktop
      ? WindowHeaderContainer(child: child)
      : VpnManager(child: child);
  final state = AppStateManager(
    child: CoreManager(
      child: ConnectivityManager(
        onConnectivityChanged: onConnectivityChanged,
        child: platformApp,
      ),
    ),
  );
  final platformState = isDesktop
      ? WindowManager(
          terminateSignals: terminateSignals,
          child: TrayManager(
            child: HotKeyManager(child: ProxyManager(child: state)),
          ),
        )
      : AndroidManager(child: TileManager(child: state));
  return AppEnvManager(
    child: LocaleManager(child: ThemeManager(child: platformState)),
  );
}

class Application extends ConsumerStatefulWidget {
  const Application({super.key});

  @override
  ConsumerState<Application> createState() => ApplicationState();
}

class ApplicationState extends ConsumerState<Application> {
  Timer? _autoUpdateProfilesTaskTimer;
  Timer? _clientUpdateTimer;
  bool _clientUpdateRunning = false;
  bool _preHasVpn = false;
  // Android's NetworkObserver resets the Core on a new network itself.
  late final _networkReset = NetworkResetTrigger(
    onReset: ref.read(coreActionProvider.notifier).resetNetwork,
  );
  // Windows can only watch SIGINT and SIGHUP.
  final _terminateSignals = system.isDesktop && !system.isWindows
      ? ProcessSignal.sigterm.watch()
      : null;

  @override
  void initState() {
    super.initState();
    SystemNavigator.setFrameworkHandlesBack(true);
    dialogs.dress = vpsDressAlert;
    vpsAskTakeover = vpsShowTakeoverAsk;
    vpsBeforeSystemProxy = vpsNoteForeignProxy;
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) async {
      if (globalState.navigatorKey.currentContext != null) {
        if (!await bootstrap.attach() || !mounted) return;
      } else {
        exit(0);
      }
      _autoUpdateProfilesTask();
      _clientUpdateTask(const Duration(seconds: 30));
      // GitHub out of reach until the proxy is up: ask again through it.
      ref.listenManual(isStartProvider, (was, on) {
        if (on && was != true && !_clientUpdateRunning) {
          final failed =
              ref.read(vpsUpdateCheckProvider).status == VpsUpdateStatus.failed;
          if (!failed) return;
          _clientUpdateTimer?.cancel();
          _clientUpdateTask(const Duration(seconds: 20));
        }
      });
      _initLink();
      if (!safeModeBuild) {
        unawaited(app?.initShortcuts());
      }
    });
  }

  void _initLink() {
    linkManager.initAppLinksListen((raw) async {
      unawaited(window?.show());
      // A member centre address imports as its subscription.
      final url = vpsSubscriptionLink(raw);
      // The link's path is the subscription's secret: name only its host,
      // so the question is short and safe on a shared screen.
      final source = vpsLinkSource(url);
      // This context sits above the app's Localizations, so ask the
      // app's current language directly.
      final zh = currentAppLocalizations.localeName.startsWith('zh');
      String tr(String zhText, String en) => zh ? zhText : en;
      final res = await dialogs.showMessage(
        title: tr('导入订阅', 'Import subscription'),
        message: TextSpan(
          children: [
            if (source == null)
              TextSpan(text: tr('要导入这个订阅吗？', 'Import this subscription?'))
            else ...[
              TextSpan(text: tr('要导入来自 ', 'Import the subscription from ')),
              TextSpan(
                text: source,
                style: TextStyle(color: context.colorScheme.primary),
              ),
              TextSpan(text: tr(' 的订阅吗？', '?')),
            ],
            TextSpan(
              text: tr(
                '\n导入后，点概览页的连接按钮即可使用。',
                '\nOnce imported, press Connect on the overview.',
              ),
            ),
          ],
        ),
      );
      if (res != true) return;
      unawaited(
        ref.read(profilesActionProvider.notifier).addProfileFromLink(url),
      );
    });
  }

  /// A newer client on GitHub, or on the panel's mirror, is fetched in the
  /// background and then offered for a one-tap install
  /// (vps2vpn/auto_update.dart).
  void _clientUpdateTask(Duration delay) {
    _clientUpdateTimer = Timer(delay, () async {
      _clientUpdateRunning = true;
      try {
        if (!safeModeBuild) await vpsAutoUpdateCheck(ref);
      } finally {
        _clientUpdateRunning = false;
      }
      if (!mounted) return;
      final failed =
          ref.read(vpsUpdateCheckProvider).status == VpsUpdateStatus.failed;
      _clientUpdateTask(
        failed ? vpsUpdateRetryInterval : vpsUpdateCheckInterval,
      );
    });
  }

  void _autoUpdateProfilesTask() {
    _autoUpdateProfilesTaskTimer = Timer(const Duration(minutes: 20), () async {
      await ref.read(profilesActionProvider.notifier).autoUpdateProfiles();
      await ref.read(resourcesActionProvider.notifier).autoUpdate();
      await ref.read(mitmModulesActionProvider.notifier).autoUpdate();
      if (!mounted) {
        return;
      }
      _autoUpdateProfilesTask();
    });
  }

  Future<void> _handleConnectivityChanged(NetworkState state) async {
    commonPrint.log(
      'connectivityChanged wifi: ${state.wifi} vpn: ${state.vpn}'
      ' resumed: ${state.resumed}',
    );
    unawaited(ref.read(systemActionProvider.notifier).updateLocalIp());
    final hasVpn = state.vpn;
    if (_preHasVpn == hasVpn) {
      ref.read(routeTrackerProvider.notifier).bumpHostEpoch();
      // Android's NetworkObserver tells the Core about a new network itself.
      if (system.isDesktop) {
        debouncer.call(
          FunctionTag.networkChange,
          ref.read(coreActionProvider.notifier).reportNetworkChange,
          duration: const Duration(milliseconds: 200),
        );
      }
    }
    _preHasVpn = hasVpn;
    if (system.isDesktop) {
      _networkReset.report(
        resumed: state.resumed,
        defaultInterface: state.defaultInterface,
      );
    }
  }

  @override
  Widget build(context) {
    return Consumer(
      builder: (_, ref, child) {
        final locale = ref.watch(
          appSettingProvider.select((state) => state.locale),
        );
        final themeProps = ref.watch(themeSettingProvider);
        final textScale = themeProps.textScale;
        final dynamicColor = ref.watch(dynamicColorProvider);
        Color seedOf(Brightness b) => themeProps.primaryColor != null
            ? Color(themeProps.primaryColor!)
            : dynamicColor.seedOf(b);
        return PrismApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: globalState.navigatorKey,
          onNavigationNotification: (_) => true,
          localizationsDelegates: const [
            appLocalizationsDelegate,
            AppUiLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          builder: (context, child) {
            return VpsAccentScope(
              light: seedOf(Brightness.light),
              dark: seedOf(Brightness.dark),
              child: vpsShotBoundary(
                buildManagerStack(
                  isDesktop: system.isDesktop,
                  onConnectivityChanged: _handleConnectivityChanged,
                  terminateSignals: _terminateSignals,
                  child: child!,
                ),
              ),
            );
          },
          title: appName,
          locale: getLocaleForString(locale),
          supportedLocales: AppLocalizations.supportedLocales,
          themeMode: themeProps.themeMode,
          theme: watchAppTheme(ref, Brightness.light),
          darkTheme: watchAppTheme(ref, Brightness.dark),
          textScale: textScale.enable ? textScale.scale : null,
          minTextScale: minTextScale,
          maxTextScale: maxTextScale,
          liquidGlass: switch (themeProps.liquidGlass) {
            LiquidGlassMode.none => null,
            LiquidGlassMode.ultra => LiquidGlassQuality.ultra,
            LiquidGlassMode.standard => LiquidGlassQuality.standard,
          },
          emojiFont: (family: FontFamily.twEmoji.value, pattern: emojiPattern),
          stackedBanners: !ref.watch(isMobileViewProvider),
          bannerTopInset: ref.watch(overlayTopOffsetProvider),
          remoteFocus: system.isTV,
          floatingKeyboard: app?.floatingKeyboard,
          onGenerateRoute: (settings) => HomeRoute(
            settings: settings,
            builder: (_) => KeyboardInsetHold(child: child!),
          ),
        );
      },
      child: const HomePage(),
    );
  }

  @override
  void dispose() {
    linkManager.destroy();
    _autoUpdateProfilesTaskTimer?.cancel();
    _clientUpdateTimer?.cancel();
    _networkReset.dispose();
    super.dispose();
  }
}
