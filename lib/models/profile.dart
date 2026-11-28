import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import 'clash_config.dart';

part 'generated/profile.freezed.dart';
part 'generated/profile.g.dart';

typedef SubscriptionHeader = String? Function(String name);

/// Why the config at the path cannot be used, or null.
typedef ValidateConfig =
    Future<String?> Function(String path, String ageSecretKey);

@freezed
abstract class SubscriptionInfo with _$SubscriptionInfo {
  const factory SubscriptionInfo({
    @Default(0) int upload,
    @Default(0) int download,
    @Default(0) int total,
    @Default(0) int expire,
    String? announce,
    String? webPageUrl,
    String? supportUrl,
  }) = _SubscriptionInfo;

  factory SubscriptionInfo.fromJson(Map<String, Object?> json) =>
      _$SubscriptionInfoFromJson(json);

  factory SubscriptionInfo.fromHeaders(SubscriptionHeader header) {
    return SubscriptionInfo.formHString(
      header('subscription-userinfo'),
    ).copyWith(
      announce: subscriptionHeaderText(
        header('announce'),
        maxLength: maxSubscriptionAnnounceLength,
      ),
      webPageUrl: subscriptionHeaderLink(
        header('profile-web-page-url'),
      )?.toString(),
      supportUrl: subscriptionHeaderLink(header('support-url'))?.toString(),
    );
  }

  factory SubscriptionInfo.formHString(String? info) {
    if (info == null) return const SubscriptionInfo();
    final Map<String, int> map = {};
    for (final field in info.split(';')) {
      final separator = field.indexOf('=');
      if (separator == -1) continue;
      final value = _parseCount(field.substring(separator + 1).trim());
      if (value != null) {
        map[field.substring(0, separator).trim().toLowerCase()] = value;
      }
    }
    return SubscriptionInfo(
      upload: map['upload'] ?? 0,
      download: map['download'] ?? 0,
      total: map['total'] ?? 0,
      expire: map['expire'] ?? 0,
    );
  }

  static int? _parseCount(String value) {
    final count = int.tryParse(value);
    if (count != null) return count;
    final decimal = double.tryParse(value);
    return decimal != null && decimal.isFinite ? decimal.truncate() : null;
  }
}

extension SubscriptionInfoExt on SubscriptionInfo {
  /// Subscription headers are untrusted. Convert the counters separately to
  /// double before addition, so two large nonnegative int64 counters cannot
  /// overflow the native integer sum or make the displayed usage negative.
  double get used {
    final up = upload > 0 ? upload.toDouble() : 0.0;
    final down = download > 0 ? download.toDouble() : 0.0;
    return up + down;
  }

  double? get usage => total > 0 ? (used / total).clamp(0.0, 1.0) : null;

  /// Only four-digit UTC calendar years are shown in the UI. The guard must
  /// come before multiplication to milliseconds or DateTime construction.
  DateTime? get expireDate => expire > 0 && expire <= 253402300799
      ? DateTime.fromMillisecondsSinceEpoch(expire * 1000)
      : null;
}

@freezed
abstract class Profile with _$Profile {
  const factory Profile({
    required int id,
    @Default(ProfileType.file) ProfileType type,
    @Default('') String label,
    String? currentGroupName,
    @Default('') String url,
    @Default('') String ageSecretKey,
    DateTime? lastUpdateDate,
    required Duration autoUpdateDuration,

    /// The user set the interval; `profile-update-interval` leaves it alone.
    @Default(false) bool userAutoUpdateDuration,
    SubscriptionInfo? subscriptionInfo,
    @Default(true) bool autoUpdate,
    @Default({}) Map<String, String> selectedMap,
    @Default({}) Set<String> unfoldSet,
    int? scriptId,
    @Default({}) Map<String, String> exitTargets,
    int? order,
    @Default(ProfileOverrides())
    @JsonKey(fromJson: ProfileOverrides.safeFromJson)
    ProfileOverrides overrides,
  }) = _Profile;

  factory Profile.fromJson(Map<String, Object?> json) =>
      _$ProfileFromJson(json);

  factory Profile.normal({String? label, String url = ''}) {
    final id = snowflake.id;
    return Profile(
      type: url.isEmpty ? ProfileType.file : ProfileType.url,
      label: label ?? '',
      url: url,
      id: id,
      autoUpdateDuration: defaultUpdateDuration,
    );
  }

  factory Profile.custom({String? label}) {
    return Profile(
      id: snowflake.id,
      type: ProfileType.custom,
      label: label ?? '',
      lastUpdateDate: DateTime.now(),
      autoUpdate: false,
      autoUpdateDuration: defaultUpdateDuration,
    );
  }
}

/// A profile leaving out one of the global rules its extension would add.
@freezed
abstract class DisabledRule with _$DisabledRule {
  const factory DisabledRule({required int profileId, required int ruleId}) =
      _DisabledRule;
}

extension ProfilesExt on List<Profile> {
  Profile? getProfile(int? profileId) {
    final index = indexWhere((profile) => profile.id == profileId);
    return index == -1 ? null : this[index];
  }

  Profile optimizeLabel(Profile profile) {
    return profile.copyWith(
      label: uniqueLabelFor(
        profile.label,
        fallback: profile.defaultLabel,
        taken: (label) =>
            any((item) => item.label == label && item.id != profile.id),
      ),
    );
  }
}

extension ProfileExtension on Profile {
  bool get realAutoUpdate => type == ProfileType.url && autoUpdate;

  String get realLabel => label.takeFirstValid([defaultLabel]);

  String get defaultLabel => url.webUri?.host ?? id.toString();

  String get fileName => '$id.yaml';

  String get exportFileName {
    final label = realLabel;
    final lower = label.toLowerCase();
    if (lower.endsWith('.yaml') || lower.endsWith('.yml')) {
      return label;
    }
    return '$label.yaml';
  }

  String get updatingKey => 'profile_$id';

  Future<bool> get waitsForFirstDownload async =>
      type == ProfileType.url && !await (await _getFile(false)).exists();

  Future<File> _getFile([bool autoCreate = true]) async {
    final path = await appPath.getProfilePath(id.toString());
    final file = File(path);
    final isExists = await file.exists();
    if (!isExists && autoCreate) {
      return file.create(recursive: true);
    }
    return file;
  }

  Future<File> get file async {
    return _getFile();
  }

  Future<Profile> update({required ValidateConfig validate}) async {
    final response = await request.getSubscriptionResponse(url);
    final bytes = decompressUnlabeled(response.data ?? Uint8List(0));
    if (_isBlank(bytes)) {
      throw MessageException(currentAppLocalizations.subscriptionEmpty);
    }
    return withSubscriptionHeaders(
      (name) => response.headers[name]?.firstOrNull,
    ).saveFile(bytes, validate: validate);
  }

  Profile withSubscriptionHeaders(SubscriptionHeader header) {
    final updateInterval = subscriptionUpdateIntervalHours(
      header('profile-update-interval'),
    );
    return copyWith(
      label: label.takeFirstValid([
        subscriptionHeaderText(
          header('profile-title'),
          maxLength: maxSubscriptionTitleLength,
        ),
        getFileNameForDisposition(header('content-disposition')),
        defaultLabel,
      ]),
      subscriptionInfo: SubscriptionInfo.fromHeaders(header),
      autoUpdateDuration: updateInterval != null && !userAutoUpdateDuration
          ? Duration(hours: updateInterval)
          : autoUpdateDuration,
    );
  }

  /// What the user changed while [target] downloaded wins over [updated].
  Profile withUpdate({required Profile target, required Profile updated}) {
    return copyWith(
      label: label.takeFirstValid([updated.label]),
      subscriptionInfo: updated.subscriptionInfo,
      lastUpdateDate: updated.lastUpdateDate,
      autoUpdateDuration:
          userAutoUpdateDuration ||
              autoUpdateDuration != target.autoUpdateDuration
          ? autoUpdateDuration
          : updated.autoUpdateDuration,
    );
  }

  Future<Profile> saveFile(
    Uint8List bytes, {
    required ValidateConfig validate,
  }) async {
    final mFile = await _getFile(false);
    final tempFile = File('${mFile.path}.$pid.$uniqueId.tmp');
    try {
      await tempFile.parent.create(recursive: true);
      await tempFile.writeAsBytes(bytes, flush: true);
      if (await validate(tempFile.path, ageSecretKey) case final issue?) {
        throw MessageException(issue);
      }
      await _renameProfileFileRetrying(tempFile, mFile.path);
      return copyWith(lastUpdateDate: DateTime.now());
    } finally {
      await tempFile.safeDelete().then((_) {}, onError: (Object _) {});
    }
  }
}

bool _isBlank(Uint8List bytes) {
  for (final byte in bytes) {
    if (byte case != 0x20 && != 0x09 && != 0x0a && != 0x0d) return false;
  }
  return true;
}

const _profileReplaceAttempts = 10;
const _profileReplaceRetryDelay = Duration(milliseconds: 50);

Future<void> _renameProfileFileRetrying(File source, String target) async {
  for (var attempt = 1; ; attempt++) {
    try {
      await source.rename(target);
      return;
    } on FileSystemException {
      if (attempt == _profileReplaceAttempts) rethrow;
      await Future<void>.delayed(_profileReplaceRetryDelay);
    }
  }
}
