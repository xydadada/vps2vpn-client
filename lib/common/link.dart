import 'dart:async';
import 'dart:io';

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
    // Invalid percent-encoded UTF-8 in an untrusted deep link must not
    // terminate the listener or leak the received URL into diagnostics.
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
    if (controller.isClosed) return;
    final uri = link is String ? Uri.tryParse(link) : null;
    if (uri != null) {
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
        // onListen is async: an unhandled platform error would otherwise
        // escape instead of reaching the stream's onError handler.
        if (!controller.isClosed) controller.addError(error, stack);
      }
    },
    onCancel: () {
      channel.setMethodCallHandler(null);
      // With the only listener cancelled, awaiting close() can wait forever
      // for an undeliverable done event. Mark closed without blocking cancel.
      unawaited(controller.close());
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
      (uri) => _handle(uri, installConfigCallBack),
      onError: (Object _, StackTrace _) {
        // A deep link can contain a full subscription credential. Do not
        // include exception.toString(), source URL, or query in logs.
        commonPrint.log('App link stream failed');
      },
    );
  }

  void _handle(Uri uri, Function(String url) installConfigCallBack) {
    if (!linkSchemes.contains(uri.scheme)) {
      return;
    }
    commonPrint.log('onAppLink: ${uri.scheme}');
    final url = _installConfigUrl(uri);
    if (url != null && url.isUrl) {
      // Catch both synchronous callbacks and rejected async callbacks.
      // Logging the original error would expose user subscription tokens.
      unawaited(
        Future<void>.sync(() async {
          await installConfigCallBack(url);
        }).catchError((Object _) {
          commonPrint.log('App link handling failed');
        }),
      );
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
