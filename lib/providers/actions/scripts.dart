part of '../action.dart';

@Riverpod(keepAlive: true)
class ScriptsAction extends _$ScriptsAction {
  final _updates = <int, Object>{};

  @override
  void build() {}

  void putScript(Script script) {
    _updates.remove(script.id);
    ref.read(scriptsProvider.notifier).put(script);
    _applyIfInUse(script.id);
  }

  void deleteScript(int scriptId) {
    _updates.remove(scriptId);
    final inUse = ref.read(currentProfileProvider)?.scriptId == scriptId;
    ref.read(scriptsProvider.notifier).del(scriptId);
    ref
        .read(profilesProvider.notifier)
        .updateWhere(
          (profile) => profile.scriptId == scriptId,
          (profile) => profile.copyWith(scriptId: null),
        );
    if (inUse) {
      ref
          .read(setupActionProvider.notifier)
          .applyProfileDebounce(silence: true);
    }
  }

  Future<void> updateScript(Script script) async {
    final current = ref.read(scriptsProvider).value?.get(script.id);
    if (current == null || current.url == null || current.url!.isEmpty) {
      return;
    }
    final token = Object();
    _updates[current.id] = token;
    bool shouldCommit() {
      if (!ref.mounted || !identical(_updates[current.id], token)) {
        return false;
      }
      final latest = ref.read(scriptsProvider).value?.get(current.id);
      return latest != null && latest.url == current.url;
    }

    final updatingKeys = ref.read(updatingKeysProvider.notifier);
    final operation = updatingKeys.start(current.updatingKey);
    try {
      final updated = await current.update(shouldCommit: shouldCommit);
      if (!shouldCommit()) {
        return;
      }
      final latest = ref.read(scriptsProvider).value!.get(current.id)!;
      ref.read(scriptsProvider.notifier).put(
        latest.copyWith(lastUpdateTime: updated.lastUpdateTime),
      );
      _applyIfInUse(current.id);
    } catch (_) {
      if (shouldCommit()) {
        rethrow;
      }
    } finally {
      if (identical(_updates[current.id], token)) {
        _updates.remove(current.id);
      }
      if (ref.mounted) {
        updatingKeys.stop(current.updatingKey, operation);
      }
    }
  }

  void _applyIfInUse(int scriptId) {
    if (ref.read(currentProfileProvider)?.scriptId != scriptId) {
      return;
    }
    ref.read(setupActionProvider.notifier).applyProfileDebounce(silence: true);
  }
}
