part of '../action.dart';

@Riverpod(keepAlive: true)
class ProfilesAction extends _$ProfilesAction {
  final Map<int, Future<void>> _profileUpdates = {};
  final _updates = <int, Object>{};

  CoreController get _core => ref.read(coreHandlerProvider);

  @override
  void build() {}

  void updateCurrentSelectedMap(String groupName, String proxyName) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile != null &&
        currentProfile.selectedMap[groupName] != proxyName) {
      final selectedMap = Map<String, String>.from(currentProfile.selectedMap)
        ..[groupName] = proxyName;
      ref
          .read(profilesProvider.notifier)
          .put(currentProfile.copyWith(selectedMap: selectedMap));
    }
  }

  /// An empty [proxyName] forgets the group's pick.
  void setSelection(int profileId, String groupName, String proxyName) {
    final profile = ref.read(profilesProvider).getProfile(profileId);
    if (profile == null ||
        (profile.selectedMap[groupName] ?? '') == proxyName) {
      return;
    }
    final selectedMap = Map<String, String>.from(profile.selectedMap);
    if (proxyName.isEmpty) {
      selectedMap.remove(groupName);
    } else {
      selectedMap[groupName] = proxyName;
    }
    ref
        .read(profilesProvider.notifier)
        .put(profile.copyWith(selectedMap: selectedMap));
  }

  Future<void> deleteProfile(int id) async {
    _updates.remove(id);
    cancelProfileWrite(id);
    final currentProfileId = ref.read(currentProfileIdProvider);
    if (currentProfileId == id) {
      final remaining = [
        for (final profile in ref.read(profilesProvider))
          if (profile.id != id) profile,
      ];
      if (remaining.isNotEmpty) {
        ref.read(currentProfileIdProvider.notifier).value = remaining.first.id;
      } else {
        ref.read(currentProfileIdProvider.notifier).value = null;
        try {
          await ref.read(setupActionProvider.notifier).setRunning(false);
        } catch (error) {
          commonPrint.log(
            'deleteProfile($id) stop failed: $error',
            logLevel: coreFailureLogLevel(error),
          );
        }
      }
    }
    await ref.read(profilesProvider.notifier).del(id);
    await clearEffect(id);
  }

  Future<String?> validateConfigWithData(List<int> data) async {
    return _core.validateConfigWithData(data);
  }

  Future<void> autoUpdateProfiles() async {
    for (final id in [
      for (final profile in ref.read(profilesProvider)) profile.id,
    ]) {
      final profile = ref.read(profilesProvider).getProfile(id);
      if (profile == null || !profile.autoUpdate) continue;
      final isNotNeedUpdate = profile.lastUpdateDate
          ?.add(profile.autoUpdateDuration)
          .isBeforeNow;
      if (isNotNeedUpdate == false || profile.type != ProfileType.url) {
        continue;
      }
      try {
        await updateProfile(profile);
      } catch (e) {
        commonPrint.log(compactError(e), logLevel: LogLevel.warning);
      }
    }
  }

  void putProfile(Profile profile, {bool select = false}) {
    _updates.remove(profile.id);
    cancelProfileWrite(profile.id);
    ref.read(profilesProvider.notifier).put(profile);
    if (!select && ref.read(currentProfileIdProvider) != null) return;
    ref.read(currentProfileIdProvider.notifier).value = profile.id;
  }

  Future<List<Profile>> providerUsers(Profile profile) async {
    if (profile.type == ProfileType.custom) {
      return const [];
    }
    final users = await ref
        .read(clashProvidersActionProvider.notifier)
        .profilesReferencing(ProviderKind.proxy, profile.realLabel);
    return [
      for (final user in users)
        if (user.id != profile.id) user,
    ];
  }

  /// Where a profile's own group takes a name, the name stands for that group.
  Future<List<Profile>> proxyUsers(Set<String> names) async {
    final (ruleTargets, dialerTargets) = await (
      database.rulesDao.targetsNaming(names),
      database.proxyDialersDao.targetsNaming(names),
    ).wait;
    final users = <Profile>[];
    for (final profile in ref.read(profilesProvider)) {
      if (profile.type != ProfileType.custom) {
        continue;
      }
      final groups = await database.proxyGroupsDao.query(profile.id).get();
      final inUse = proxyNamesInUse(
        names.difference({for (final group in groups) group.name}),
        groups: groups,
        ruleTargets: ruleTargets[profile.id] ?? const {},
        dialerTargets: dialerTargets[profile.id] ?? const {},
        overrides: profile.overrides,
      );
      if (inUse.isNotEmpty) {
        users.add(profile);
      }
    }
    return users;
  }

  Future<Set<String>> groupsInUse(int profileId, Set<int> groupIds) async {
    final groups = await database.proxyGroupsDao.query(profileId).get();
    final names = {
      for (final group in groups)
        if (groupIds.contains(group.id)) group.name,
    };
    final (ruleTargets, dialerTargets) = await (
      database.rulesDao.targetsNaming(names),
      database.proxyDialersDao.targetsNaming(names),
    ).wait;
    return proxyNamesInUse(
      names,
      groups: groups.where((group) => !groupIds.contains(group.id)),
      ruleTargets: ruleTargets[profileId] ?? const {},
      dialerTargets: dialerTargets[profileId] ?? const {},
      overrides:
          ref.read(profilesProvider).getProfile(profileId)?.overrides ??
          const ProfileOverrides(),
    );
  }

  Future<void> updateProfiles() async {
    for (final id in [
      for (final profile in ref.read(profilesProvider)) profile.id,
    ]) {
      final profile = ref.read(profilesProvider).getProfile(id);
      if (profile == null || profile.type != ProfileType.url) continue;
      await updateProfile(profile, showLoading: true);
    }
  }

  ({bool Function() isCurrent, VoidCallback release}) _claimProfileWrite(
    Profile source,
  ) {
    final token = Object();
    _updates[source.id] = token;
    return (
      isCurrent: () {
        if (!ref.mounted || !identical(_updates[source.id], token))
          return false;
        final latest = ref.read(profilesProvider).getProfile(source.id);
        return latest != null &&
            latest.type == source.type &&
            latest.url == source.url &&
            latest.ageSecretKey == source.ageSecretKey;
      },
      release: () {
        if (identical(_updates[source.id], token)) _updates.remove(source.id);
      },
    );
  }

  /// The editor and remote refreshes share ownership of the saved bytes.
  Future<bool> saveProfileFile(Profile profile, Uint8List bytes) async {
    final current = ref.read(profilesProvider).getProfile(profile.id);
    if (current == null) return false;
    final claim = _claimProfileWrite(current);
    try {
      final saved = await profile.saveFile(
        bytes,
        validate: (path, key) => _core.validateProfile(path, key),
        shouldCommit: claim.isCurrent,
      );
      if (!claim.isCurrent()) return false;
      final latest = ref.read(profilesProvider).getProfile(profile.id)!;
      ref
          .read(profilesProvider.notifier)
          .put(
            latest.copyWith(
              label: profile.label,
              url: profile.url,
              ageSecretKey: profile.ageSecretKey,
              autoUpdate: profile.autoUpdate,
              autoUpdateDuration: profile.autoUpdateDuration,
              lastUpdateDate: saved.lastUpdateDate,
            ),
          );
      return true;
    } catch (_) {
      if (claim.isCurrent()) rethrow;
      return false;
    } finally {
      claim.release();
    }
  }

  void renameProfile(int id, String label) {
    if (!ref.mounted) return;
    final latest = ref.read(profilesProvider).getProfile(id);
    if (latest != null) putProfile(latest.copyWith(label: label));
  }

  Future<bool> saveProfileEdit(
    Profile original,
    Profile edited, {
    Uint8List? bytes,
    Future<void> Function()? beforeRefresh,
    bool Function()? canCommit,
  }) async {
    if (original.id != edited.id || original.type != edited.type) return false;
    final claim = _claimProfileWrite(original);
    bool current() => claim.isCurrent() && canCommit?.call() != false;
    Profile merge(Profile latest) => latest.copyWith(
      label: latest.label == original.label ? edited.label : latest.label,
      url: edited.url,
      ageSecretKey: edited.ageSecretKey,
      autoUpdate: latest.autoUpdate == original.autoUpdate
          ? edited.autoUpdate
          : latest.autoUpdate,
      autoUpdateDuration:
          latest.autoUpdateDuration == original.autoUpdateDuration
          ? edited.autoUpdateDuration
          : latest.autoUpdateDuration,
    );

    try {
      if (!current()) return false;
      final needsRefresh =
          edited.type == ProfileType.url &&
          (edited.url != original.url ||
              edited.ageSecretKey != original.ageSecretKey);
      Profile? saved;
      if (bytes != null) {
        saved = await edited.saveFile(
          bytes,
          validate: (path, key) => _core.validateProfile(path, key),
          shouldCommit: current,
        );
      } else if (needsRefresh) {
        await beforeRefresh?.call();
        if (!current()) return false;
        saved = await edited.update(
          validate: (path, key) => _core.validateProfile(path, key),
          shouldCommit: current,
        );
      }
      if (!current()) return false;
      final latest = ref.read(profilesProvider).getProfile(original.id)!;
      var result = merge(latest);
      if (saved != null) {
        result = result.copyWith(
          lastUpdateDate: saved.lastUpdateDate,
          subscriptionInfo: needsRefresh
              ? saved.subscriptionInfo
              : latest.subscriptionInfo,
        );
      }
      ref.read(profilesProvider.notifier).put(result);
      if (saved != null && ref.read(currentProfileIdProvider) == original.id) {
        ref
            .read(setupActionProvider.notifier)
            .applyProfileDebounce(silence: true);
      }
      return true;
    } catch (_) {
      if (current()) rethrow;
      return false;
    } finally {
      claim.release();
    }
  }

  /// Setup repairs a missing subscription without scheduling another setup.
  Future<void> updateMissingProfile(Profile profile) async {
    if (profile.type != ProfileType.url) return;
    final path = await appPath.getProfilePath(profile.id.toString());
    if (await File(path).exists() || !ref.mounted) return;
    await updateProfile(profile, reapply: false);
  }

  Future<void> updateProfile(
    Profile profile, {
    bool showLoading = false,
    bool reapply = true,
  }) {
    // Requests for the same profile can race. Do not serialize behind a
    // stalled validator: the newer write-ownership claim supersedes the old.
    final completer = Completer<void>();
    _profileUpdates[profile.id] = completer.future;
    final operation = showLoading
        ? ref.read(updatingKeysProvider.notifier).start(profile.updatingKey)
        : null;
    return () async {
      void Function() releaseClaim = () {};
      bool Function()? isCurrent;
      try {
        if (!ref.mounted) return;
        final target = ref.read(profilesProvider).getProfile(profile.id);
        if (target == null || target.type != ProfileType.url) return;
        // A scheduled refresh receives a snapshot that can be stale by the
        // time it runs. Never overwrite the stored URL or encryption key.
        final claim = _claimProfileWrite(target);
        isCurrent = claim.isCurrent;
        releaseClaim = claim.release;
        final updated = await target.update(
          validate: (path, key) => _core.validateProfile(path, key),
          shouldCommit: claim.isCurrent,
        );
        if (!claim.isCurrent()) return;
        // The download can take minutes; edits and deletes made meanwhile win.
        final latest = ref.read(profilesProvider).getProfile(target.id);
        if (latest == null) {
          await clearEffect(target.id);
          return;
        }
        if (latest.url != target.url ||
            latest.ageSecretKey != target.ageSecretKey) {
          return;
        }
        final newProfile = latest.copyWith(
          label: latest.label.takeFirstValid([updated.label]),
          subscriptionInfo: updated.subscriptionInfo,
          lastUpdateDate: updated.lastUpdateDate,
          autoUpdateDuration:
              latest.autoUpdateDuration != target.autoUpdateDuration
              ? latest.autoUpdateDuration
              : updated.autoUpdateDuration,
        );
        ref.read(profilesProvider.notifier).put(newProfile);
        if (!reapply) return;
        if (target.id == ref.read(currentProfileIdProvider)) {
          ref
              .read(setupActionProvider.notifier)
              .applyProfileDebounce(silence: true);
        } else {
          final label = ref
              .read(profilesProvider.notifier)
              .labeled(newProfile)
              .realLabel;
          unawaited(
            ref.read(clashProvidersActionProvider.notifier).applyIfReferenced(
              ProviderKind.proxy,
              {label},
              force: true,
            ),
          );
        }
      } catch (_) {
        // A superseded or deleted profile must not show an obsolete network
        // error. Current requests still propagate their failures to callers.
        if (isCurrent?.call() == false) return;
        rethrow;
      } finally {
        releaseClaim();
        if (identical(_profileUpdates[profile.id], completer.future)) {
          _profileUpdates.remove(profile.id);
        }
        if (!completer.isCompleted) {
          completer.complete();
        }
        if (operation != null && ref.mounted) {
          ref
              .read(updatingKeysProvider.notifier)
              .stop(profile.updatingKey, operation);
        }
      }
    }();
  }

  Future<void> addProfileFormFile() async {
    final platformFile = await globalState.safeRun(picker.pickerFile);
    if (platformFile == null) return;
    final bytes = await platformFile.readBytes();
    globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    ref.read(currentPageLabelProvider.notifier).toProfiles();
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () => _withAgeSecretKey(
        Profile.normal(label: platformFile.name),
        (profile) => profile.saveFile(
          bytes,
          validate: (path, key) => _core.validateProfile(path, key),
        ),
      ),
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile);
    }
  }

  int addCustomProfile(String label) {
    final profile = Profile.custom(label: label);
    putProfile(profile);
    return profile.id;
  }

  void touchProfile(int id) {
    final profile = ref.read(profilesProvider).getProfile(id);
    if (profile == null) return;
    ref
        .read(profilesProvider.notifier)
        .put(profile.copyWith(lastUpdateDate: DateTime.now()));
  }

  Future<CustomProfileImport> readCustomImport(
    int profileId,
    Uint8List bytes,
  ) async {
    final profiles = ref.read(profilesProvider);
    final (ruleProviders, proxies, groupNames) = await (
      database.clashProvidersDao.query().get(),
      database.customProxiesDao.query().get(),
      database.proxyGroupsDao.names(except: profileId).get(),
    ).wait;
    final CustomImportApp app = (
      profileLabels: {
        for (final profile in profiles) ...[profile.label, profile.realLabel],
      },
      profileSources: {
        for (final profile in profiles)
          if (profile.type == ProfileType.url)
            (url: profile.url, ageSecretKey: profile.ageSecretKey):
                profile.realLabel,
      },
      ruleProviderLabels: {
        for (final provider in ruleProviders) provider.label,
      },
      ruleProviderSources: {
        for (final provider in ruleProviders)
          if (provider.isRemote)
            (url: provider.url, ageSecretKey: ''): provider.label,
      },
      proxies: [for (final proxy in proxies) proxy.definition],
      groupNames: groupNames.toSet(),
    );
    try {
      return await compute(readCustomProfileImport, (bytes: bytes, app: app));
    } on CustomImportException catch (error) {
      final appLocalizations = currentAppLocalizations;
      throw MessageException(switch (error.issue) {
        CustomImportIssue.unreadable => appLocalizations.importConfigInvalid,
        CustomImportIssue.ruleType => appLocalizations.failedItem(
          error.item,
          appLocalizations.ruleTextInvalid,
        ),
        CustomImportIssue.entry => appLocalizations.failedItem(
          error.item,
          error.detail,
        ),
      });
    }
  }

  /// [config] replaces what [profileId] holds. The providers it adds are saved
  /// before the groups and rules naming them, and loaded afterwards; the
  /// future completes once they have loaded.
  Future<void> importCustomProfile(int profileId, CustomProfileImport config) {
    final profiles = ref.read(profilesProvider.notifier);
    final clashProviders = ref.read(clashProvidersProvider.notifier);
    final loads = <({String label, Future<void> Function() load})>[];
    for (final (:label, :url, :ageSecretKey, :content)
        in config.proxyProviders) {
      final profile = Profile.normal(
        label: label,
        url: url,
      ).copyWith(ageSecretKey: ageSecretKey);
      profiles.put(profile);
      loads.add((
        label: label,
        load: url.isNotEmpty
            ? () => updateProfile(profile, showLoading: true)
            : () async => profiles.put(
                await profile.saveFile(
                  utf8.encode(content),
                  validate: (path, key) => _core.validateProfile(path, key),
                ),
              ),
      ));
    }
    for (final (:label, :url, ageSecretKey: _, :content)
        in config.ruleProviders) {
      final provider = ClashProvider.create(label: label, url: url);
      clashProviders.put(provider);
      loads.add((
        label: label,
        load: url.isNotEmpty
            ? () => ref
                  .read(resourcesActionProvider.notifier)
                  .updateRuleProvider(provider)
            : () => ref
                  .read(clashProvidersActionProvider.notifier)
                  .putProvider(provider, content: utf8.encode(content)),
      ));
    }
    final customProxies = ref.read(customProxiesProvider.notifier);
    customProxies.putAll([
      for (final definition in config.proxies)
        CustomProxy.fromDefinition(definition),
    ]);
    final proxyIds = {
      for (final proxy in customProxies.value) proxy.name: proxy.id,
    };
    ref.read(proxyGroupsProvider(profileId).notifier).setAll([
      for (final group in config.proxyGroups) group.copyWith(id: snowflake.id),
    ]);
    ref.read(profileRulesProvider(profileId).notifier).setAll([
      for (final rule in config.rules) rule.copyWith(id: snowflake.id),
    ]);
    ref.read(proxyDialersProvider(profileId).notifier).setAll({
      for (final MapEntry(:key, :value) in config.dialers.entries)
        ?proxyIds[key]: value,
    });
    profiles.updateProfile(
      profileId,
      (profile) => profile.copyWith(overrides: config.overrides),
    );
    return globalState.batchRun(
      loads,
      (item) => item.load(),
      label: (item) => item.label,
      concurrency: maxConcurrentImports,
      tag: null,
    );
  }

  void _showProfiles() {
    if (globalState.navigatorKey.currentState?.canPop() ?? false) {
      globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    ref.read(currentPageLabelProvider.notifier).value = PageLabel.profiles;
  }

  Future<void> addProfileFromLink(
    String link, {
    String? label,
    String ageSecretKey = '',
  }) async {
    _showProfiles();
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () => link.isShareLink
          ? _fromShareLinks(Profile.normal(label: label), [link])
          : _withAgeSecretKey(
              Profile.normal(
                label: label,
                url: link,
              ).copyWith(ageSecretKey: ageSecretKey),
              _download,
            ),
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile, select: true);
    }
  }

  /// Ids are taken up front so the list keeps the order of [links]; the share
  /// links among them make up one profile, in the place of the first.
  Future<void> addProfilesFromLinks(List<String> links) async {
    _showProfiles();
    final shareLinks = [
      for (final link in links)
        if (link.isShareLink) link,
    ];
    await globalState.batchRun(
      [
        for (final link in links)
          if (!link.isShareLink)
            (profile: Profile.normal(url: link), shareLinks: const <String>[])
          else if (link == shareLinks.first)
            (profile: Profile.normal(), shareLinks: shareLinks),
      ],
      (item) async => putProfile(
        await (item.shareLinks.isEmpty
            ? _download(item.profile)
            : _fromShareLinks(item.profile, item.shareLinks)),
      ),
      label: (item) => item.shareLinks.firstOrNull ?? item.profile.url,
      concurrency: maxConcurrentImports,
      tag: LoadingTag.profiles,
    );
  }

  Future<Profile> _download(Profile profile) {
    return profile.update(
      validate: (path, key) => _core.validateProfile(path, key),
    );
  }

  Future<Profile> _withAgeSecretKey(
    Profile profile,
    Future<Profile> Function(Profile profile) save,
  ) async {
    try {
      return await save(profile);
    } on AgeSecretKeyRequiredException {
      final key = (await dialogs.showAgeSecretKeyInput())?.trim();
      if (key == null || key.isEmpty) {
        rethrow;
      }
      return save(profile.copyWith(ageSecretKey: key));
    }
  }

  Future<Profile> _fromShareLinks(Profile profile, List<String> links) async {
    final appLocalizations = currentAppLocalizations;
    final decoded = await _core.decodeShareLinks(links);
    final taken = {...reservedCustomProxyNames};
    final proxies = <Map<String, dynamic>>[];
    for (final (index, definitions) in decoded.indexed) {
      if (definitions.isEmpty) {
        throw MessageException(
          links.length == 1
              ? appLocalizations.shareLinksInvalid
              : appLocalizations.shareLinkUnreadable(links[index]),
        );
      }
      for (final definition in definitions) {
        final name = freeProxyName(linkProxyName(definition), taken);
        proxies.add({...definition, 'name': name});
      }
    }
    final first = proxies.first['name'] as String;
    final label = proxies.length == 1
        ? first
        : appLocalizations.proxiesProfileLabel(first, proxies.length);
    final config = await encodeYamlTask({'proxies': proxies});
    return profile
        .copyWith(label: profile.label.takeFirstValid([label]))
        .saveFile(
          utf8.encode(config),
          validate: (path, _) => _core.validateConfig(path),
        );
  }

  Future<void> addProfileFormQrCode() async {
    final url = await globalState.safeRun(picker.pickerConfigQRCode);
    if (url == null) return;
    unawaited(addProfileFromLink(url));
  }

  Future<void> clearEffect(int profileId) async {
    cancelProfileWrite(profileId);
    final profilePath = await appPath.getProfilePath(profileId.toString());
    final profileFile = File(profilePath);
    final isExists = await profileFile.exists();
    if (isExists) {
      await profileFile.safeDelete(recursive: true);
    }
    try {
      await _core.clearEffect(profileId);
    } catch (error) {
      commonPrint.log(
        'clearEffect($profileId) failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
      try {
        final providersRoot = await appPath.getProvidersRootPath();
        await Directory(
          join(providersRoot, profileId.toString()),
        ).safeDelete(recursive: true);
      } catch (fallbackError) {
        commonPrint.log(
          'clearEffect($profileId) local cleanup failed: $fallbackError',
          logLevel: LogLevel.warning,
        );
      }
    }
  }
}
