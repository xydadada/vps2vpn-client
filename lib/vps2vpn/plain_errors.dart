import 'package:fl_clash/l10n/l10n.dart';

/// Plain words for the Core and system errors that reach the user as raw
/// text; null keeps the raw text. Network failures have their own mapping.
String? vpsPlainError(String raw, AppLocalizations l10n) {
  final zh = l10n.localeName.startsWith('zh');
  String say(String cn, String en) => zh ? cn : en;
  final t = raw.toLowerCase();
  bool has(List<String> words) => words.any(t.contains);

  if (has([
    'bind:',
    'address already in use',
    'only one usage of each socket',
  ])) {
    return say(
      '本机端口被别的软件占着。请关掉别的代理软件，或在「设置」里打开"连接时自动接管"，然后再试。',
      'A port vps2vpn needs is taken by another app. Quit other proxy apps, or turn on "Take over on Connect" in Settings, then try again.',
    );
  }
  if (has(['wintun', 'tun device', 'create tun', 'configure tun', 'elevat'])) {
    return say(
      '虚拟网卡没能打开。请在「概览」里改用"系统代理"，或重新安装 vps2vpn 后再试。',
      'The virtual adapter did not start. Switch to System proxy on the Overview, or reinstall vps2vpn, then try again.',
    );
  }
  if (has(['x509', 'certificate has expired', 'certificate is not valid'])) {
    return say(
      '证书校验没通过，常见原因是电脑的日期或时间不对。请校准时间后再试。',
      'A certificate check failed, usually because the PC clock is off. Fix the date and time, then try again.',
    );
  }
  if (has([
    'yaml',
    'unmarshal',
    'a config must be a mapping',
    'rules must be a list',
    'decrypt config',
  ])) {
    return say(
      '订阅内容读不懂，可能链接不完整或服务器返回了错误页面。请向管理员确认链接。',
      'The subscription could not be read; the link may be incomplete or the server sent an error page. Check the link with the owner.',
    );
  }
  if (has([
    'access is denied',
    'permission denied',
    'operation not permitted',
  ])) {
    return say(
      '系统拒绝了这次操作，可能被安全软件拦住了。请允许 vps2vpn 后再试。',
      'Windows refused this, possibly a security app. Allow vps2vpn, then try again.',
    );
  }
  if (has(['out of file descriptors', 'too many open files'])) {
    return say(
      '同时打开的连接太多了。请断开后重新连接。',
      'Too many connections are open. Disconnect and connect again.',
    );
  }
  return null;
}
