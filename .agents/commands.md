# Commands

`make` is the entry point on macOS and Linux: `make help` lists every target with its variables, generated from the
`##` comments in the `Makefile`, and `test/tool/makefile_test.dart` keeps the two in step. Each target only calls the
command this file documents, so the logic stays in `tool/`; `make doctor` names a missing toolchain, `make check`
runs the local root checks, and `make core-check` and `make core-test` check the Go wrapper. The current fork's CI
commands are listed under Verify below; the inherited Make targets are not an exact copy of those jobs.
`make run` starts the safe mode build required by the shared-host development rules.

## Building

Update submodules first. The ClashMeta Go core lives in `core/Clash.Meta/`, the UI library in `plugins/prism_ui/`.

```bash
git submodule update --init --recursive
```

Full package build, including Go core, Flutter, and packaging, runs through `tool/package.dart` (`make package`,
`make package-android`, with `ARCH=`, `FORM=` and `DRY=1`). Run it with `dart`, not `dart run`, which first runs
every build hook for the host:

```bash
dart tool/package.dart                     # this host: dmg, exe + zip, or deb + AppImage + rpm
dart tool/package.dart android             # every ABI; --arch arm64 for one
dart tool/package.dart linux --dry-run --arch arm64   # names and steps only, any platform
```

Artifacts land in `dist/`, alongside `manifest.json` and a checksum file. Use the dry-run output and the manifest
for the current environment's exact names; the fork's Windows workflow also prepares the installer names expected
by the vps2vpn panel. See Packaging in `architecture.md`.

The desktop Go core and the Rust helper build automatically: Flutter runs
`plugins/setup/hook/build.dart` on every `flutter build` and `flutter test`,
and the hook drives `CoreBuilder` from the `setup_hooks` package in
`plugins/setup/setup_hooks/`. Artifacts land in `libclash/`. Android's Core is
the AAR the `:core` Gradle module builds with `gomobile bind` before anything
compiles against it; that needs `go` on `PATH` and nothing else, since the
gomobile tools come from `core/go.mod` and the NDK from AGP. The hook reruns only when Go, Rust, or
`setup_hooks` inputs change; the fingerprint cache lives in
`.dart_tool/setup_build_cache/`. To force a rebuild, delete that directory:

```bash
rm -rf .dart_tool/setup_build_cache
```

Flutter hides the hook's output on success, so to see why the Core was or was
not rebuilt read `.dart_tool/setup_build_cache/hook.log`; each invocation starts
with a `===` line carrying its timestamp and target.

Both Rust builds, the Helper and `rust_api`, pass `--remap-path-prefix` so no
local path lands in a binary. With neither `RUSTFLAGS` nor
`CARGO_ENCODED_RUSTFLAGS` set, the flags go into `CARGO_TARGET_<TRIPLE>_RUSTFLAGS`,
which Cargo joins with `target.<triple>.rustflags` from a Cargo config but which
leaves `build.rustflags` unread, so put custom flags under the target table.
Either variable set, or a home, checkout or Cargo home path with a space, sends
the flags through `CARGO_ENCODED_RUSTFLAGS` instead, and Cargo then reads no
rustflags from its config.

The hook runs for `flutter test` and for `dart run` of any root-package script
too, so a pure Dart test run needs the Go toolchain, and on Linux and Windows
also `cargo` and `rustc` — the Helper fingerprint shells out to both even on a
cache hit. The hook protocol carries no build mode and no caller, so the only
switch is the user-define in the root `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    setup:
      build_assets: true   # false turns the Go core and Helper hook into a no-op
    rust_api:
      build_assets: true   # false does the same for the Rust library
```

The current `verify.yaml` keeps both hooks enabled and installs Go and Rust for the root test job. The editor tests
in `test/plugins/code_forge/` and the socket test in `test/core/desktop/ipc_native_test.dart` load the Rust library
the hook builds. There is no separate release-notes job in this fork's checked-in workflows.
Never commit `false`: a build with it set stages whatever `libclash/` already
holds and bundles no Rust library, which is why `tool/package.dart` refuses to package
while it is set. Locally, `false` is worth setting for a Dart-only test loop,
but the hook cache keys on the user-define, so the first build afterwards runs
the hooks again. The editor and IPC socket tests still need the Rust library: keep `rust_api`
on, or point `FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR` at a directory that
holds a `rust_api` library built from the same sources.

## Flutter Development

Use the default Flutter SDK directly:

```bash
flutter pub get
flutter run --dart-define-from-file=env.json --dart-define=SAFE_MODE=true
flutter test
```

Use `flutter test`, not `dart test`, because models pull in Flutter types.

A development build takes over the host exactly like a release: it creates the TUN device, sets the system proxy, on
macOS registers the TUN as the system resolver, registers itself as the login item, and on Windows and Linux starts its
Core through the privileged Helper shared by installed copies of this app, which can stop an existing Core. Data isolation
also depends on the target: macOS debug uses `com.follow.clash.debug`; Android uses `com.vps2vpn.client.dev` for debug
and for release builds without the configured release signing key. Windows and Linux builds share the installed app's
data directory and preferences. Safe mode suppresses host changes in the Dart/Core paths that honor the flag and
leaves the Core's listeners and external controller unopened. Windows native startup can still clear stale system-proxy
settings before the Dart guard runs; [#101](https://github.com/xydadada/vps2vpn-client/issues/101) tracks that boundary,
so `SAFE_MODE` does not yet guarantee complete host isolation:

```bash
flutter run --dart-define-from-file=env.json --dart-define=SAFE_MODE=true
```

The build is bannered `SAFE MODE`, the tray shows the
`status_4` bug icon with a menu of only show and exit and no traffic title, and the settings keep their values, so
nothing has to be flipped back before a normal run. See the safe mode section of `architecture.md` for the owners that consult the flag.

## Code Generation

Run code generation after modifying models, providers, or database schema:

```bash
dart run build_runner build --delete-conflicting-outputs
dart run build_runner watch
```

Code generation covers:

- Riverpod providers through `riverpod_generator`.
- Models through `freezed` and `json_serializable`.
- Database tables through `drift_dev`.

The Dart-Rust bindings in `plugins/rust_api` are generated by `flutter_rust_bridge_codegen` from
`plugins/rust_api/flutter_rust_bridge.yaml`; rerun it from that directory after changing anything under
`rust/src/api/`:

```bash
cd plugins/rust_api && flutter_rust_bridge_codegen generate
```

Generated output paths, configured in each package's `build.yaml`:

- `lib/models/generated/*.g.dart`, `*.freezed.dart`.
- `lib/providers/generated/*.g.dart`.
- `lib/database/generated/*.g.dart`.

Localizations in `lib/l10n/` come from the ARB files in `arb/` through Flutter's `gen-l10n`, configured in `l10n.yaml`.
`flutter pub get` regenerates them, since `pubspec.yaml` sets `generate: true`; after editing an ARB file alone:

```bash
flutter gen-l10n
```

Tray and Windows app icons are generated, not hand-edited. `assets_source/images/icon/*.svg` is
the source of truth; the script needs `rsvg-convert` (librsvg) on `PATH`:

```bash
dart run tool/generate_status_icons.dart
```

It writes the tray PNGs with Flutter `2.0x/`–`4.0x/` resolution variants to `assets/images/tray/unix/`,
multi-size tray `.ico` files to `assets/images/tray/windows/`, and `windows/runner/resources/app_icon.ico`
from `assets/images/icon.png`. `status_1`–`status_3` are the logo glyph alone and tell stopped, running and TUN
apart only by color, so they carry no rings or shadow. macOS draws its menu bar icon as a template by default,
where color is lost: `status_1` renders the bare logo from `assets_source/images/icon/glyph.svg` and `status_4`
reuses `status_4.svg`, both recolored to black into `assets/images/tray/macos/`; the sources keep their colors.
With the tray menu's monochrome icon turned off, macOS loads the color PNGs from `assets/images/tray/unix/`.
`glyph.svg` is also the geometry of the Android notification drawables
`android/service/src/main/res/drawable/ic.xml` and `ic_service.xml`; change them together. `pubspec.yaml` declares the three tray directories with `platforms:` so each
build only bundles the formats its tray loads; a new status icon needs a source SVG and an entry in the
script's `statusIconNames`, nothing in `pubspec.yaml`.

## Testing

Tests use `package:test/test.dart` for pure Dart logic and `flutter_test` for provider and widget tests. `mocktail` is the mocking framework.

```bash
flutter test test/models/
flutter test test/core/
flutter test test/core/desktop/
flutter test test/providers/
flutter test test/common/
flutter test test/database/
flutter test test/widgets/
flutter test test/setup_test.dart
```

For the whole suite, or a directory of more than a few files, use `tool/test.dart`, which is also what CI runs:

```bash
dart run tool/test.dart                                  # all of test/
dart run tool/test.dart test/widgets test/views          # some paths
dart run tool/test.dart -- --reporter expanded --coverage
```

Plain `flutter test` compiles each file into its own program and starts an engine for it, one file after another, and
that dominates a full run. `tool/test.dart` imports the files into 32 generated entrypoints under
`.dart_tool/test_bundles/` and runs those with one worker per core, about half the time of a plain run, and less than
a third with `--coverage`. Files in one entrypoint share an
isolate, so a test can see state a file before it left behind; the script runs every file that failed there again on
its own, lets that run decide, and names the files that only failed together. See the Shared Test Isolate section of
`rules.md` before fixing one.

`plugins/setup/setup_hooks/` is a pure Dart package and is tested with `dart test` from its own directory, which is
also what CI runs; `tool/check_plugins.sh` does not descend into it. It must stay out of `flutter test`, because a test
run of `plugins/setup` would execute the build hook itself.

`tool/check_plugins.sh` only analyzes and tests the Dart side. The fork's automatic verification does not include
a desktop Flutter build matrix. The manual Windows and Android workflows compile their respective applications;
macOS and Linux native plugin changes still need a build on the corresponding platform.

Root `flutter test` only discovers the root package's `test/` directory by default. Include bundled plugin Dart tests by passing paths explicitly, or run `flutter test` from that plugin package directory, or run `bash tool/check_plugins.sh` to analyze and test every plugin package the way CI does. Native plugin tests under platform folders are not run by `flutter test`.

For the current Core/service architecture, useful focused checks are:

```bash
flutter test test/core/desktop/
flutter test test/core/service_test.dart
flutter test test/core/protocol_contract_test.dart
flutter test test/manager/core_manager_test.dart
flutter test test/providers/action_test.dart test/providers/system_action_test.dart
flutter test test/views/dashboard/live_status_test.dart
```

What those suites own:

- `test/core/desktop/`: replaceable IPC transport, RPC request correlation/failure, direct/Helper process leases, and
  latest-intent desktop lifecycle convergence. `ipc_native_test.dart` runs the transport over a real socket through
  the Rust `IpcServer`; the server's own behavior is covered by `cargo test` in `plugins/rust_api/rust`.
- `test/core/service_test.dart`: `CoreService` composition and terminal close behavior.
- `test/core/protocol_contract_test.dart`: shared Dart/Go method and event-envelope compatibility, including event batches.
- `test/providers/action_test.dart`: Core start/restart orchestration and overlapping restart requests.
- `test/providers/system_action_test.dart`: ordered, idempotent exit cleanup and watchdog behavior.
- `test/views/dashboard/live_status_test.dart`: 600-millisecond starting presentation hold, immediate failure display,
  the order of the live status deck, where it sits, a list opening in place, and the confirmation before a force
  restart.

## Native Component Verification

These focused local Go-wrapper checks run without CGO. The Android vet command covers its platform files except
the cgo one in `timezone/`, which only the gomobile build compiles. The full CI commands are listed under Verify:

```bash
cd core
CGO_ENABLED=0 go test .
CGO_ENABLED=0 go vet . ./cmd/...
GOOS=android GOARCH=arm64 CGO_ENABLED=0 go vet -tags=with_gvisor . ./mobile ./tun ./platform
```

The Windows Helper's loopback/session protocol tests are host-independent by default. Windows CI additionally enables its
service implementation:

```bash
cargo fmt --manifest-path services/helper/Cargo.toml -- --check
cargo test --manifest-path services/helper/Cargo.toml
cargo test --manifest-path services/helper/Cargo.toml --features windows-service
```

The last command requires Windows for meaningful service coverage. Native Android lifecycle edits should at minimum
compile the modules they touch, with the JDK 17 that CI installs. On macOS the Homebrew `openjdk@17` keg is not
registered with `java_home`, so export it by prefix:

```bash
cd android
export JAVA_HOME="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"   # elsewhere: any JDK 17
./gradlew :core:compileDebugKotlin -Ptarget-platform=android-arm64   # builds the gomobile AAR for one ABI
./gradlew :service:compileDebugKotlin
./gradlew :app:compileDebugKotlin
```

Always-on VPN entry, system VPN revoke, actual permission UI, and rapid device start/stop still require Android device or
emulator validation; Kotlin compilation cannot prove those system callbacks.

## Fork Builds And Publishing

`HANDOFF.md` records the fork's current release status and verification evidence. The checked-in build workflows
are manual (`workflow_dispatch`), with publishing disabled by default:

| Workflow | Purpose | Explicit publishing option |
| --- | --- | --- |
| `.github/workflows/vps2vpn.yaml` | Build the Windows installer and run takeover checks on a disposable runner | `publish=true` signs update payloads and uploads a `test-<version>` prerelease |
| `.github/workflows/android.yaml` | Build the signed Android APK and run emulator checks | `publish=true` adds the update signature and uploads a `test-android-<version>` prerelease; experiment builds cannot publish |
| `e2e.yaml`, `coexist.yaml`, `harsh.yaml`, `screenshots.yaml`, `android-probe.yaml`, `android-testlab.yaml` | Explicitly requested installer, coexistence, UI, or Android investigations | Read each workflow's inputs and host effects before dispatching it |

A prerelease is promoted separately by the maintainer after review. A normal source change needs a branch and PR;
it does not require a tag, workflow dispatch, or Release. Do not infer publishing authorization from a request to
review or test code.

### Retained Upstream Changelog Tools

`tool/changelog.dart` and `tool/release.sh` came from upstream FlClash and retain upstream repository links and
release assumptions. The fork's publishing workflows are listed above. In particular, `tool/release.sh --push`
creates commits/tags and pushes them; its comments about automatic upstream publication do not describe the
workflows present here.

The retained changelog tool derives `CHANGELOG.md` and `changelog.json` from Conventional Commits and supports
`Changelog:` trailers described in `.agents/rules.md`. Its local verification/rendering commands remain useful
when maintaining that upstream history:

```bash
dart run tool/changelog.dart verify
dart run tool/changelog.dart markdown
dart run tool/changelog.dart render release --out release.md
dart run tool/changelog.dart render telegram --out telegram.md
```

`markdown` and `render` write local files. `verify` checks only versions whose tags are reachable from `HEAD`,
so skipped versions do not mean their history was validated. The fork's source-verification workflow does not
run this changelog tool or publish its output. Keep inherited release notes separate from claims about a new
vps2vpn release.

## Verify

`.github/workflows/verify.yaml` runs on pushes, pull requests, and manual dispatch, with read-only repository
contents permission. It verifies source; it does not publish installers or Releases. Its jobs are:

- `go`: validate and apply the hash-pinned Core patches, run the wrapper tests (including the race detector) and
  vet with `with_gvisor`, and cross-build the Windows Core.
- `dart`: install the pinned Flutter/Go/Rust toolchains and Linux native build dependencies, enforce the root
  lockfile, analyze, run the root test bundle with coverage, check bundled plugins, and analyze/test `setup_hooks`.
- `rust`: test the Rust API and Helper on Linux and Windows, enabling the Helper's `windows-service` feature on Windows.

The root-package part of the Dart job is:

```bash
flutter pub get --enforce-lockfile
flutter analyze --no-fatal-infos
dart run tool/test.dart -- --reporter expanded --coverage
bash tool/check_plugins.sh
```

The pure Dart build-hook checks run from `plugins/setup/setup_hooks`:

```bash
dart pub get --enforce-lockfile
dart analyze
dart test --reporter expanded
```

The workflow uploads `coverage/lcov.info` and `.dart_tool/test_bundles/report.json` even when a test step fails.
It does not currently enforce the 75-percent coverage floor, Dart formatting, or hook-script checks. Those are
additional local checks in `make check`; `make coverage` explicitly applies the local coverage floor.

`tool/hooks/` holds the git-hook scripts. Run `bash tool/hooks/test.sh` after changing one; it discovers each
`*_test.sh` beside them. `tool/check_plugins.sh` discovers the top-level local plugin packages, while
`setup_hooks` needs the separate commands above. Root analysis and tests alone do not cover those packages.

### Toolchains And Caches

The current verification pins live in `verify.yaml`: Flutter and Go in its `env`, Rust in the install steps.
Keep the corresponding manual Windows/Android build pins aligned when upgrading. Verification uses the Flutter,
Go, and Rust action caches; inspect the workflow's actual keys and workspaces when diagnosing a stale cache.
The removed upstream `BRANCH_CACHE`, `desktop`, `upload`, and tag-release jobs do not describe this fork's CI.

## Worktree Tooling

```bash
bash tool/worktrees.sh list       # every worktree with owner tool and dirty/clean state
bash tool/worktrees.sh prune      # remove clean worktrees; add --force to drop dirty ones too
```
