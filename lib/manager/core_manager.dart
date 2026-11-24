import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/route_state.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/vps2vpn/crash_restart.dart';
import 'package:fl_clash/vps2vpn/panel.dart';
import 'package:fl_clash/vps2vpn/stale_refresh.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/banner.dart';

class CoreManager extends ConsumerStatefulWidget {
  final Widget child;

  const CoreManager({super.key, required this.child});

  @override
  ConsumerState<CoreManager> createState() => _CoreContainerState();
}

class _CoreContainerState extends ConsumerState<CoreManager>
    with CoreEventListener {
  CoreController get _core => ref.read(coreHandlerProvider);
  final _crashRestarts = VpsCrashRestarts();

  // vps2vpn: see lib/common/tun_self_check.dart. Windows only, where FlClash
  // #3020 shows TUN "on" with no adapter.
  late final _tunSelfCheck = TunSelfCheck(
    readStatus: () => _core.getTunStatus(),
    currentStack: () => ref.read(patchClashConfigProvider).tun.stack,
    switchStack: (stack) => ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith.tun(stack: stack)),
    notify: _notifyTunCheck,
  );

  @override
  Widget build(BuildContext context) {
    ref.watch(vpsLineWatchProvider);
    ref.watch(vpsStaleRefreshProvider);
    ref.watch(vpsPanelSyncProvider);
    return widget.child;
  }

  @override
  void initState() {
    super.initState();
    coreEventManager.addListener(this);
    ref.read(updatingActionProvider.notifier);
    // A rejected profile stays selected on purpose: silently reverting to
    // the previous one hides the error and looks like the switch was lost.
    ref.listenManual(currentProfileIdProvider, (prev, next) {
      if (prev == next) return;
      runAfterFrame(() {
        unawaited(ref.read(setupActionProvider.notifier).fullSetup());
      });
    });
    ref.listenManual(updateParamsProvider, (prev, next) {
      if (prev != next) {
        ref.read(setupActionProvider.notifier).updateConfigDebounce();
      }
    });
    ref.listenManual(setupPatchProvider, (prev, next) {
      if (prev != next) {
        ref
            .read(setupActionProvider.notifier)
            .applyProfileDebounce(silence: true);
      }
    });
    ref.listenManual(globalRulesProvider, (prev, next) {
      if (prev?.value != null && next.hasValue) {
        ref.read(setupActionProvider.notifier).applyIfGlobalRulesUsed();
      }
    });
    ref.listenManual(
      patchClashConfigProvider.select((state) => state.mitm.enable),
      (prev, next) {
        if (prev == false && next) {
          unawaited(ref.read(mitmModulesActionProvider.notifier).autoUpdate());
        }
      },
    );
    ref.listenManual(mitmModulesProvider, (prev, next) {
      if (rsFeature &&
          prev?.value != null &&
          next.hasValue &&
          ref.read(patchClashConfigProvider).mitm.enable) {
        ref
            .read(setupActionProvider.notifier)
            .applyProfileDebounce(silence: true);
      }
    });
    ref.listenManual(appSettingProvider.select((state) => state.openLogs), (
      prev,
      next,
    ) {
      if (prev != next) {
        _syncLogStream();
      }
    });
    if (system.isWindows) {
      ref.listenManual(
        patchClashConfigProvider.select((state) => state.tun.enable),
        (_, _) => _syncTunSelfCheck(),
      );
      ref.listenManual(isStartProvider, (_, _) => _syncTunSelfCheck());
      ref.listenManual(coreStatusProvider, (_, _) => _syncTunSelfCheck());
    }
    // Every Core process starts without a log stream.
    ref.listenManual(coreStatusProvider, (prev, next) {
      if (next == CoreStatus.connected && prev != CoreStatus.connected) {
        _syncLogStream();
      }
    }, fireImmediately: true);
  }

  void _syncLogStream() {
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }
    if (ref.read(appSettingProvider).openLogs) {
      _core.startLog();
    } else {
      _core.stopLog();
    }
  }

  /// Checks a few seconds after TUN is asked for on a running, reachable
  /// Core; switching TUN off or disconnecting forgets the retry, so the next
  /// enable or connect gets one.
  void _syncTunSelfCheck() {
    // A disconnect ends the session too: a check under way then must not
    // switch the stack, and the next connect is checked again.
    if (!ref.read(patchClashConfigProvider).tun.enable ||
        !ref.read(isStartProvider)) {
      _tunSelfCheck.reset();
      return;
    }
    if (ref.read(isStartProvider) &&
        ref.read(coreStatusProvider) == CoreStatus.connected &&
        !ref.read(safeModeProvider)) {
      _tunSelfCheck.schedule();
    }
  }

  void _notifyTunCheck(TunCheckStep step, TunStack from, TunStack? to) {
    final zh = currentAppLocalizations.localeName.startsWith('zh');
    switch (step) {
      case TunCheckStep.retry:
        dialogs.showBanner(
          zh
              ? '虚拟网卡（TUN）未能用 ${from.name} 协议栈启动，已自动改用 ${to?.name} 重试'
              : 'TUN did not start on the ${from.name} stack; retrying on ${to?.name}',
          level: BannerLevel.warning,
        );
      case TunCheckStep.giveUp:
        dialogs.showBanner(
          zh
              ? '虚拟网卡（TUN）未能启动。可打开「局域网兼容模式」（关闭严格路由）后重试，或改用系统代理'
              : 'TUN could not start. Try LAN compatibility mode (strict route off), or use the system proxy',
          level: BannerLevel.error,
        );
      case TunCheckStep.keep:
        break;
    }
  }

  @override
  void dispose() {
    _tunSelfCheck.dispose();
    coreEventManager.removeListener(this);
    super.dispose();
  }

  @override
  Future<void> onDelay(Delay delay) async {
    super.onDelay(delay);
    final proxiesAction = ref.read(proxiesActionProvider.notifier);
    proxiesAction.setDelay(delay);
    debouncer.call(FunctionTag.updateDelay, () async {
      proxiesAction.updateGroupsDebounce();
    }, duration: const Duration(milliseconds: 5000));
  }

  @override
  void onLog(Log log) {
    ref.read(logsProvider.notifier).add(log);
    if (log.logLevel == LogLevel.error) {
      throttler.call(
        FunctionTag.coreErrorNotifier,
        () => dialogs.showBanner(log.payload, level: BannerLevel.error),
        duration: const Duration(seconds: 3),
        fire: true,
      );
    }
    super.onLog(log);
  }

  @override
  void onDialerLoop(String proxyName) {
    throttler.call(
      FunctionTag.dialerLoopNotifier,
      () => dialogs.showBanner(
        currentAppLocalizations.dialerProxyLoopStopped(proxyName),
        level: BannerLevel.error,
      ),
      duration: const Duration(seconds: 3),
      fire: true,
    );
    super.onDialerLoop(proxyName);
  }

  @override
  void onRequest(TrackerInfo trackerInfo) async {
    ref.read(requestsProvider.notifier).addRequest(trackerInfo);
    ref.read(requestCountProvider.notifier).update((count) => count + 1);
    super.onRequest(trackerInfo);
  }

  @override
  void onRequestTraffic(Map<String, RequestTraffic> traffic) {
    ref.read(requestsProvider.notifier).updateTraffic(traffic);
    super.onRequestTraffic(traffic);
  }

  @override
  void onDns(DnsQuery dnsQuery) {
    ref.read(dnsQueriesProvider.notifier).addQuery(dnsQuery);
    ref.read(dnsQueryCountProvider.notifier).update((count) => count + 1);
    super.onDns(dnsQuery);
  }

  @override
  Future<void> onLoaded(String providerName) async {
    final provider = await _core.getExternalProvider(providerName);
    if (!mounted) {
      return;
    }
    ref.read(providersProvider.notifier).setProvider(provider);
    debouncer.call(FunctionTag.loadedProvider, () async {
      if (!mounted) {
        return;
      }
      ref.read(proxiesActionProvider.notifier).updateGroupsDebounce();
    }, duration: const Duration(milliseconds: 5000));
    super.onLoaded(providerName);
  }

  @override
  Future<void> onCrash(String message) async {
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }
    ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    ref.read(coreStopReasonProvider.notifier).value = message;
    final setup = ref.read(setupActionProvider.notifier)..onCoreLost();
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      dialogs.showBanner(message, level: BannerLevel.error);
    }
    // vps2vpn: onCoreLost already put the system proxy back; restartCore
    // brings the run back too, but only while wantsRunning.
    if (system.isDesktop && setup.wantsRunning && _crashRestarts.take()) {
      Future<void>.delayed(const Duration(seconds: 2), () {
        if (!mounted ||
            ref.read(coreStatusProvider) != CoreStatus.disconnected) {
          return;
        }
        unawaited(
          globalState.safeRun(
            ref.read(coreActionProvider.notifier).restartCore,
          ),
        );
      });
    }
    super.onCrash(message);
  }

  @override
  void onGeoUpdate(String geoType, bool updating, bool skipped, String? error) {
    ref
        .read(geoResourceActionProvider.notifier)
        .handleCoreUpdate(geoType, updating, skipped, error);
    super.onGeoUpdate(geoType, updating, skipped, error);
  }

  @override
  void onRouteChanged(RouteSnapshot snapshot) {
    ref.read(routeTrackerProvider.notifier).applySnapshot(snapshot);
    super.onRouteChanged(snapshot);
  }
}
