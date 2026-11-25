// vps2vpn: the adapter is up a moment before its routes and DNS carry a page.

import 'dart:async';
import 'dart:io';

import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _patience = Duration(seconds: 15);
const _try = Duration(seconds: 3);

final vpsTunReadyProvider = FutureProvider.autoDispose<bool>((ref) async {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return true;
  final on = ref.watch(isStartProvider) && !ref.watch(suspendProvider);
  final tun = ref.watch(patchClashConfigProvider.select((s) => s.tun.enable));
  if (!on || !tun) return true;
  final url = Uri.tryParse(ref.read(patchClashConfigProvider).testUrl);
  if (url == null) return true;
  var gone = false;
  ref.onDispose(() => gone = true);
  final stop = DateTime.now().add(_patience);
  while (!gone && DateTime.now().isBefore(stop)) {
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = _try;
    try {
      final req = await client.getUrl(url).timeout(_try);
      final res = await req.close().timeout(_try);
      await res.drain<void>().timeout(_try);
      if (res.statusCode < 500) return true;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    } finally {
      client.close(force: true);
    }
  }
  return false;
});
