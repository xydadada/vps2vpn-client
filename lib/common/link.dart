import 'dart:async';
import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rust_api/link.dart';

import 'constant.dart';
import 'print.dart';
import 'protocol.dart';
import 'string.dart';

String? profileUrlFromQrCodes(Iterable<String?> values) {
  for (final value in values) {
    final text = value?.trim();
    if (text == null || text.isEmpty) {
      continue;
    }
    if (text.isUrl || text.isShareLink) {
      return text;
    }
    final uri = Uri.tryParse(text);
    if (uri == null || !linkSchemes.contains(uri.scheme)) {
      continue;
    }
    final url = _installConfigUrl(uri);
    if (url != null && url.isUrl) {
      return url;
    }
  }
  return null;
}

String? _installConfigUrl(Uri uri) {
  if (uri.host != 'install-config') {
    return null;
  }
  try {
    final url = uri.queryParameters['url']?.trim();
    return url == null || url.isEmpty ? null : url;
  } on FormatException {
    return null;
  }
}

const _linkChannel = MethodChannel('$packageName/link');

/// The links Android hands MainActivity. The plugin holds those that come
/// before `takeLinks` and pushes the rest, holding again any nobody takes.
@visibleForTesting
Stream<Uri> androidLinks([MethodChannel channel = _linkChannel]) {
  late final StreamController<Uri> controller;
  void add(Object? link) {
    final uri = link is String ? Uri.tryParse(link) : null;
    if (uri != null && !controller.isClosed) {
      controller.add(uri);
    }
  }

  controller = StreamController<Uri>(
    onListen: () async {
      channel.setMethodCallHandler((call) async {
        if (call.method != 'link') {
          throw MissingPluginException();
        }
        add(call.arguments);
      });
      try {
        final pending = await channel.invokeListMethod<String>('takeLinks');
        pending?.forEach(add);
      } catch (error, stack) {
        if (!controller.isClosed) controller.addError(error, stack);
      }
    },
    onCancel: () {
      channel.setMethodCallHandler(null);
      return controller.close();
    },
  );
  return controller.stream;
}

class LinkManager {
  static LinkManager? _instance;
  StreamSubscription? subscription;

  LinkManager._internal();

  @visibleForTesting
  Stream<Uri> Function() uriLinkStream = () =>
      Platform.isAndroid ? androidLinks() : desktopLinks();

  Future<void> initAppLinksListen(
    Function(String url) installConfigCallBack,
  ) async {
    destroy();
    subscription = uriLinkStream().listen(
      (uri) {
        unawaited(
          _handle(uri, installConfigCallBack).catchError((Object error) {
            commonPrint.log(
              'App link handling failed (${error.runtimeType})',
              logLevel: LogLevel.warning,
            );
          }),
        );
      },
      onError: (Object error) {
        commonPrint.log(
          'App link stream failed (${error.runtimeType})',
          logLevel: LogLevel.warning,
        );
      },
    );
  }

  Future<void> _handle(
    Uri uri,
    Function(String url) installConfigCallBack,
  ) async {
    if (!linkSchemes.contains(uri.scheme)) {
      return;
    }
    final url = _installConfigUrl(uri);
    if (url != null) {
      commonPrint.log('onAppLink: install-config');
      await Future<void>.sync(() => installConfigCallBack(url));
    }
  }

  void destroy() {
    if (subscription != null) {
      subscription?.cancel();
      subscription = null;
    }
  }

  factory LinkManager() {
    _instance ??= LinkManager._internal();
    return _instance!;
  }
}

final linkManager = LinkManager();
