# Project Context

This repository is `xydadada/vps2vpn-client`, the vps2vpn fork of FlClash, on the `vps2vpn` branch. It is a Flutter
proxy client based on ClashMeta (mihomo), focused on Windows with an Android build path. The inherited code also
contains macOS and Linux support. Start with `HANDOFF.md`, `README.md`, and `DESIGN.md` for this fork's current
status, user-facing behavior, and visual direction; `README_FlClash.md` preserves upstream documentation.

The advanced interface uses the `prism_ui` package. The default vps2vpn interface has its own design and navigation;
upstream UI conventions do not replace the fork's design requirements.

## Version Notes

- Flutter stays on the 3.50.x line. Release CI pins 3.50.0 and is the source
  of truth for release builds; `.fvmrc` and local SDKs may sit on another 3.50
  patch. `pubspec.yaml` requires Flutter 3.50.0, because the app imports
  `ScrollCacheExtent` through `package:flutter/widgets.dart`, which re-exports it
  only from 3.50.
- Before moving the pin, walk `flutter-upgrade.md`: it lists the workarounds tied to
  the current SDK, such as the guard against a wrong-size back buffer on macOS.
- The Dart SDK lower bound in `pubspec.yaml` sets the package language
  version. `flutter analyze` excludes `lib/**/generated/**`, so a raise is
  proven by `flutter test`, which parses the generated code, not by analyze.
  The root package stays at 3.10 while the SDK is 3.14: at 3.13 and above
  `dart format` rewrites about 190 files and `final` parameters stop compiling,
  and APIs marked `@Since("3.14")`, such as `rangeEquals` on typed data, fail
  analysis with `sdk_version_since` until the bound moves.

## Forked Dependencies

The root `pubspec.yaml` currently uses hosted packages and local plugin paths, with no Git dependency entry.
`core/Clash.Meta` and `plugins/prism_ui` are Git submodules pinned by this repository. Review a submodule update
against its recorded commit and the fork's callers and tests before advancing it.

The `chen08209` repositories below belong to the upstream FlClash maintainer, not this fork's owner. These notes
record the origins of code that has since moved into this tree; they do not imply control of an upstream repository.

The `window_manager` fork (`chen08209/window_manager`, tag `v0.5.1-flclash.3`)
was replaced by an in-repo plugin, now rust_api's `window/` module; the behaviors
it carried (work-area maximize with a hidden title bar on Windows, geometry
restore on re-map on Linux, corner preference, terminate and activate events)
live there, see Desktop Window in `architecture.md`.

The `launch_at_startup` fork (`chen08209/launch_at_startup`) was replaced by the
`launch` module of `plugins/rust_api`, which reads and writes the same entries; see
"rust_api Crate Layout" in `architecture.md`.

The `yaml_writer` fork (`chen08209/yaml_writer`) was replaced by
`lib/common/yaml_writer.dart`. Its key quoting let keys such as `!a`, `'a` or
`0x1F` reach the Core's yaml.v3 as a parse error or a non-string; a merge key
`<<` stays plain on purpose, because `package:yaml` keeps it as an ordinary key
and the Core applies the merge.

The `code_forge` fork (`chen08209/code_forge`) is frozen: its Dart code now lives
in the in-repo `plugins/code_forge` package and its Rust code in the `editor/`
module of `plugins/rust_api`, both trimmed to what FlClash uses.
`plugins/code_forge/README.md` records what was kept and what was removed;
upstream's MIT notice stays in `plugins/code_forge/LICENSE`.

## Dependency Ceilings

These notes record dependency constraints observed during previous upgrades. Run `flutter pub outdated` against
the current lockfile before deciding whether they still apply:

- `intl` is intentionally unbounded (`any`), which is not a bound this repository
  sets.

Other recorded upgrade constraints:

- `flutter_riverpod` 3.5.0 depends on `material_ui`, so a plain
  `flutter pub upgrade` brings `material_ui` and `cupertino_ui` into the lock
  file. Nothing fails when it does: `test/lint/design_package_test.dart` checks
  imports, not the lock file.
- `freezed` 4.0.3 needs `analyzer` 14; both resolve once the lock file is
  refreshed.
- `test` 1.33.0 needs `test_api` 0.7.15, and `flutter_test` on Flutter 3.50 pins
  0.7.14. It moves with the SDK.
- `android_file_picker` 2.1.5, the newest, from `file_picker` 13, still
  configures AGP's legacy `LibraryExtension`, which the new DSL does not
  register, so it keeps `android.newDsl=false` in `android/gradle.properties`.
  It is the only plugin that does: with a copy configuring
  `com.android.build.api.dsl.LibraryExtension`, the app builds with the new
  DSL on. The plugin waits on Flutter's migration (flutter/flutter#180137).

When an upgrade fails version solving, record the blocker here with
what has to change upstream before the pin can move, so the next
`flutter pub outdated` run does not rediscover it.

`_initDynamicColor` in `lib/bootstrap.dart` takes the system's seeds and accent color from `DynamicColorPlugin`,
in the plugin at `plugins/dynamic_color`, which keeps the native side out of the UI library's
own tree. Everything downstream sees `DynamicColorSeeds`.

## Build Dependencies

Linux:

```bash
sudo apt-get install ninja-build libgtk-3-dev libsecret-1-dev
```

Windows:

- GCC and Inno Setup.

macOS:

```bash
npm install -g appdmg
```
