import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import 'clash_config.dart';

part 'generated/profile.freezed.dart';
part 'generated/profile.g.dart';

final class ProfileUpdateSuperseded implements Exception {
  const ProfileUpdateSuperseded();
}

final _profileWriteIntents = <int, Object>{};
final _profileFileQueues = <String, Future<void>>{};

class _ProfileWriteIntent {
  _ProfileWriteIntent(this.id, this.canCommit) {
    _profileWriteIntents[id] = this;
  }

  final int id;
  final bool Function()? canCommit;

  void check() {
    if (!identical(_profileWriteIntents[id], this) ||
        canCommit?.call() == false) {
      throw const ProfileUpdateSuperseded();
    }
  }

  void release() {
    if (identical(_profileWriteIntents[id], this)) {
      _profileWriteIntents.remove(id);
    }
  }
}

void cancelProfileWrite(int id) {
  _profileWriteIntents.remove(id);
}

Future<T> _withProfileFile<T>(
  String path,
  Future<T> Function(File file) action,
) {
  final previous = _profileFileQueues[path] ?? Future<void>.value();
  final result = previous.then((_) => action(File(path)));
  late final Future<void> settled;
  settled = result.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
    if (identical(_profileFileQueues[path], settled)) {
      _profileFileQueues.remove(path);
    }
  });
  _profileFileQueues[path] = settled;
  return result;
}

Future<void> deleteProfileFile(int id) async {
  cancelProfileWrite(id);
  final path = await appPath.getProfilePath(id.toString());
  await _withProfileFile(path, (file) => file.safeDelete(recursive: true));
}

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
  }) = _SubscriptionInfo;

  factory SubscriptionInfo.fromJson(Map<String, Object?> json) =>
      _$SubscriptionInfoFromJson(json);

  factory SubscriptionInfo.formHString(String? info) {
    if (info == null) return const SubscriptionInfo();
    final Map<String, int> map = {};
    for (final field in info.split(';')) {
      final separator = field.indexOf('=');
      if (separator == -1) continue;
      final key = field.substring(0, separator).trim().toLowerCase();
      final rawValue = field.substring(separator + 1).trim();
      final value = _parseCount(rawValue);
      if (key == 'expire') {
        map[key] = value == 0 && num.tryParse(rawValue) != 0 ? -1 : value ?? -1;
      } else if (value != null) {
        map[key] = value;
      }
    }
    return SubscriptionInfo(
      upload: map['upload'] ?? 0,
      download: map['download'] ?? 0,
      total: map['total'] ?? 0,
      expire: map['expire'] ?? 0,
    );
  }

  static int? _parseCount(String value) =>
      nonNegativeInt(int.tryParse(value) ?? double.tryParse(value));
}

extension SubscriptionInfoExt on SubscriptionInfo {
  int get used => addTrafficBytes(upload, download);

  int get remaining => total > used ? total - used : 0;

  double? get usage => total > 0 ? (used / total).clamp(0.0, 1.0) : null;

  DateTime? get expireDate => expire > 0 ? dateTimeFromUnixSeconds(expire) : null;
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

  Future<Profile?> checkAndUpdateAndCopy({
    required ValidateConfig validate,
    bool Function()? canCommit,
  }) async {
    if (canCommit?.call() == false) {
      throw const ProfileUpdateSuperseded();
    }
    if (type != ProfileType.url) return null;
    final mFile = await _getFile(false);
    final exists = await mFile.exists();
    if (canCommit?.call() == false) {
      throw const ProfileUpdateSuperseded();
    }
    if (exists) return null;
    return update(validate: validate, canCommit: canCommit);
  }

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

  Future<Profile> update({
    required ValidateConfig validate,
    bool Function()? canCommit,
  }) async {
    final intent = _ProfileWriteIntent(id, canCommit);
    try {
      final response = await request.getFileResponseForUrl(url);
      intent.check();
      final disposition = response.headers.value('content-disposition');
      final userinfo = response.headers.value('subscription-userinfo');
      return await copyWith(
        label: label.takeFirstValid([
          getFileNameForDisposition(disposition),
          defaultLabel,
        ]),
        subscriptionInfo: SubscriptionInfo.formHString(userinfo),
      )._saveFile(
        decompressUnlabeled(response.data ?? Uint8List(0)),
        validate: validate,
        intent: intent,
      );
    } finally {
      intent.release();
    }
  }

  Future<Profile> saveFile(
    Uint8List bytes, {
    required ValidateConfig validate,
    bool Function()? canCommit,
  }) async {
    final intent = _ProfileWriteIntent(id, canCommit);
    try {
      return await _saveFile(bytes, validate: validate, intent: intent);
    } finally {
      intent.release();
    }
  }

  Future<Profile> _saveFile(
    Uint8List bytes, {
    required ValidateConfig validate,
    required _ProfileWriteIntent intent,
  }) async {
    final path = await appPath.getProfilePath(id.toString());
    final directory = File(path).parent;
    await directory.create(recursive: true);
    final staging = await directory.createTemp('.import-');
    try {
      intent.check();
      final tempFile = File('${staging.path}/profile.yaml');
      await tempFile.writeAsBytes(bytes, flush: true);
      final issue = await validate(tempFile.path, ageSecretKey);
      intent.check();
      if (issue != null) {
        throw MessageException(issue);
      }
      await _withProfileFile(
        path,
        (target) => tempFile.renameReplacing(
          target.path,
          beforeAttempt: intent.check,
        ),
      );
      return copyWith(lastUpdateDate: DateTime.now());
    } finally {
      await staging.safeDelete(recursive: true);
    }
  }
}
