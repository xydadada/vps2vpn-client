final class MessageException implements Exception {
  final String message;

  const MessageException(this.message);

  @override
  String toString() => message;
}

final class AgeSecretKeyRequiredException implements Exception {
  const AgeSecretKeyRequiredException();
}

/// [reason] is DownloadManager's COLUMN_REASON, null without a download.
final class SystemDownloadException implements Exception {
  final int? reason;

  const SystemDownloadException(this.reason);

  @override
  String toString() => 'SystemDownloadException: $reason';
}

final class ReleaseNotVerifiedException implements Exception {
  final String name;

  const ReleaseNotVerifiedException(this.name);

  @override
  String toString() => 'ReleaseNotVerifiedException: $name';
}

final class SubscriptionTooLargeException implements Exception {
  final int limit;

  const SubscriptionTooLargeException(this.limit);

  @override
  String toString() => 'SubscriptionTooLargeException: over $limit bytes';
}

/// A script, icon set or module past its download limit.
final class DownloadTooLargeException implements Exception {
  final int limit;

  const DownloadTooLargeException(this.limit);

  @override
  String toString() => 'DownloadTooLargeException: over $limit bytes';
}
