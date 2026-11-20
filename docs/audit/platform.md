# Platform and native audit

Baseline: `5860a5ba2ab6001869586561fccb56309db6c3e1` (`vps2vpn`), reviewed on 2026-11-20.

## Scope and evidence

This document covers the privileged Helper, desktop launch/proxy/IPC/network adapters, selected Android service boundaries, native build hooks, packaging, and CI. The full inventory is [platform-coverage.tsv](platform-coverage.tsv). It records each tracked file separately. A `manual-full` entry means the entire human-written file was read, including its tests; it does not mean every platform behavior was executed. `manual-partial` explicitly names the read range. Generated bindings, binary assets, dependency locks/licenses, and inventory-only files are not counted as manual source review.

The platform inventory contains 466 files: 72 fully read, 1 partially read, 24 generated, 26 binary/assets, 8 locks/licenses, and 335 inventory-only. This is a focused deep audit of the highest-risk native boundaries, not a claim that every inherited native/UI file was reviewed line by line. The main client report records the complementary Dart/Go review.

Both public submodules were initialized at their existing pinned revisions. Their source is a separate dependency boundary, not included in the count of project files reviewed here:

- `core/Clash.Meta`: `5b453f80dbcee6b3ecfb0415bcace24a48c88707`.
- `plugins/prism_ui`: `6c47901cc80b5325bdb9650579ca2e000a60b39e`.

## Confirmed findings and changes

All line numbers below refer to the baseline so they remain meaningful as the patch moves code. The PR Files changed view contains the complete diff.

| ID | Severity | Baseline location | Cause and effect | Repair |
|---|---|---|---|---|
| P1 | High reliability/security boundary | `services/helper/src/service/hub.rs:124` and `:460` | A started Windows Core was passed to a fallible `ManagedCore::adopt`. Windows Job creation/configuration/assignment failure dropped the `Child` without terminating or waiting for it; the preceding infallible thread-spawn wrapper could also panic before adoption on OS thread exhaustion. The privileged Core then remained alive without a managed lease; retries could start additional processes. | Adopt ownership immediately after OS process creation, then confine it before creating the stderr reader. Use fallible thread creation. On either setup error, terminate and reap the owned Core. If termination itself fails, retain the lease and return `coreStopFailed`, so subsequent starts cannot silently lose ownership. |
| P2 | High security boundary | `services/helper/src/service/linux.rs:181` | Service installation checked only the Helper executable and its immediate directory. A root-owned app directory below an ancestor writable by another user can be renamed/replaced, turning a one-time installation approval into a replaceable executable started as root at boot. | Resolve the executable and verify every ancestor through the filesystem root: UID 0, no group/other write permission, and no symlink in the checked chain. Reject control characters and non-UTF-8 unit paths before writing `ExecStart`, preventing malformed or injected systemd directives. |
| P3 | Medium | `plugins/rust_api/rust/src/launch/entries.rs:7`, `launch/windows.rs` | The Windows Run registry value was a bare executable path. Paths containing spaces are ambiguous under Windows command-line parsing; an earlier matching executable prefix can be chosen, and ordinary autostart can fail. | Quote newly written executable paths. Read both the new quoted form and the exact old bare form for upgrade compatibility, without accepting extra arguments or other commands. Normalize exact legacy bare entries during the enabled-state check when the user registry is writable, rechecking the value before changing it. Normalization leaves StartupApproved unchanged. A registry write failure remains best-effort. |
| P4 | Medium | `plugins/rust_api/rust/src/launch/linux.rs:18` | Linux autostart wrote an unquoted `Exec` value and unescaped display text. Spaces split the executable; `%` becomes a desktop field code; quotes, backslashes, and control characters can break the entry or create another key. | Encode desktop string values, quote the executable as a single argument, escape reserved command characters, and double literal `%`. Keep the established autostart filename and removal behavior. |
| P5 | Medium reliability | `plugins/rust_api/rust/src/proxy/pac.rs:39` and `:60` | Every loopback connection created an unbounded OS thread. A five-second timeout applied separately to each read or write, so a local peer could keep a request alive by periodically sending or consuming bytes and exhaust threads. Repeated accept errors also had no backoff. | Admit at most 32 concurrent workers with an RAII permit; close excess connections; back off on accept errors; retain the 16 KiB header limit; and enforce a single five-second deadline for the header and response, captured before spawning the worker. Recalculate the remaining write timeout after every partial write. |
| P6 | Build-blocking | `.gitmodules` | Both public submodules used SSH URLs, so an otherwise anonymous fresh HTTPS clone required separately configured SSH credentials. | Use HTTPS for both public URLs while retaining the exact gitlink revisions. An anonymous recursive initialization succeeded before the environment interruption. |

## Regression coverage

- Helper: injected confinement and stderr-reader startup failures must clear the owned process only after termination/reaping. Existing tests continue to check stop confirmation, session ownership, Windows job-close cleanup, and shutdown behavior.
- Linux installation: reject a user-owned, group-writable, world-writable, or symlink ancestor above the immediate application directory; visit the complete safe path through `/`; reject relative paths and control/non-UTF-8 service paths.
- Windows autostart: write a quoted path with spaces; recognize exact legacy values; reject unrelated commands and extra arguments.
- Linux autostart: encode spaces, quotes, backslashes, dollar signs, backticks, and percent field codes; prevent newline-created desktop entry keys; preserve write/remove/id/display-name behavior.
- PAC: enforce and release the admission limit; reject oversized headers; accept a complete ordinary header; reject a slow stream within one total deadline while bytes continue arriving; release a worker when a peer does not read a large response before the deadline.

## Validation actually observed

| Command/check | Observed result | What it proves and does not prove |
|---|---|---|
| `cargo test --locked` in `services/helper` with Rust 1.100.0 on Linux | 48 tests passed after the process-ownership repair, before the Linux ancestor/path regressions were added. | The first Helper edit compiled and passed its portable suite. This is not a pass for the final reconstructed tree or Windows Job/SCM behavior. |
| Standalone `rustc --edition=2021 --test` for `launch/entries.rs` | 5 passed. | The first version of the Windows command representation and compatibility logic passed pure Rust tests. No Windows registry was modified or exercised. |
| Standalone `rustc --edition=2021 --test` for `launch/linux.rs` | 4 passed. | The first desktop-entry encoding and filesystem fixture tests passed. Real desktop session autostart was not exercised. |
| `cargo test --locked` in `plugins/rust_api/rust` | Blocked during native dependency discovery: development `glib-2.0` pkg-config metadata was missing. | Crate retrieval and partial compilation succeeded; a full native bridge pass was not observed. |
| `git submodule update --init --recursive` after the HTTPS change | Both pinned submodules initialized successfully. | Fresh public dependency retrieval no longer required SSH credentials in the observed environment. |

The workspace executor became unavailable while additional toolchains/development packages and validation were being prepared. The changes were then reconstructed from the pinned baseline and uploaded as GitHub blobs. Consequently, the earlier local results above must not be presented as validation of the final PR commit. The first PR checkpoint below validated the initial reconstruction, including Linux ancestor and header-budget tests. Follow-up process-thread and response-write deadline repairs, formatting/code-generation checks, and legacy Run migration still require their own final-head result. No actual system proxy, TUN, login item, installed service, or installer takeover was activated on the shared host.

## CI checkpoints

The first PR head `a874604522feb175c87a18af2d319e762bedd876` was checked in [Actions run 44716274559](https://github.com/xydadada/vps2vpn-client/actions/runs/44716274559):

| Job | Observed result |
|---|---|
| Ubuntu native | Helper: 51 passed; native bridge: 133 passed. |
| Windows native | Helper default: 41 passed; Windows service feature: 44 passed; native bridge: 100 passed. |
| Flutter tooling | Both shell hook test files passed. The documented directory-shaped Node test argument failed under Node 22 before Flutter analysis/tests. The workflow now passes the actual `*.test.js` files; the failure is not represented as a Flutter test pass. |

These results belong to that exact intermediate head. Later native repairs and final delivery status must be evaluated from the corresponding PR head/check runs.

## PR validation

`.github/workflows/audit-checks.yaml` runs on pull requests and manual dispatch, with read-only repository permissions:

- Go 1.27.4: changed-file gofmt checks, full wrapper tests and vet, Android-specific vet, and the root wrapper race suite.
- Rust 1.99.0, matching the native hook pin: Helper and bridge tests on Ubuntu and Windows; the Windows service feature gets its own run.
- Flutter 3.50.0: changed-file dart-format checks that fail on a diff, build-runner output consistency checks, analysis, the complete root test suite, plugin checks, setup-hook package tests, and shell/Node tooling tests.

The Go/Helper build hook is disabled only in the disposable Flutter test checkout, following the project's documented test configuration. The Rust bridge hook stays enabled because editor and native IPC tests load it. Production `pubspec.yaml` remains enabled. The CA bundle is downloaded by its existing pinned filename and SHA-256. New workflow action references are pinned to commit SHAs resolved from the official repositories. The workflow does not publish, install an application, start a privileged service, or merge a PR.

## Reviewed boundary behavior without a confirmed defect

- IPC framing is length-bounded; the outbox and connection closure paths were read with their tests. Unix peer permissions and the Windows Helper owner/peer restrictions were traced independently of application-level session IDs.
- The Helper pins the Core SHA-256, validates session IDs/addresses, bounds request bodies, rejects browser origins/rebound hosts, serializes managed-process transitions, and retains ownership on failed cleanup.
- Android `FilesProvider` canonicalizes the requested path and enforces application-file-root containment; the manifest protects document access with `MANAGE_DOCUMENTS`. The VPN and proxy services are not exported.
- Android TUN descriptor transfer was traced with the Go reviewer: argument/duplication failures close the original descriptor; the duplicated descriptor passes to the TUN owner; Java callback failures map to failed lookup values rather than escaping as a pending JNI exception. No normal-path descriptor leak was confirmed.
- The script runtime has a wall-clock interrupt and memory ceiling. The desktop network monitor coalesces event bursts with a maximum delay. These mechanisms were read; target-platform stress/load behavior was not measured.

## Unverified areas and follow-up

1. Run the final PR gates and resolve every failure before merge. Formatter, compiler, and test output must be attributed to the final head, not the pre-interruption checkout.
2. Validate Windows Job-assignment failure and kill-on-helper-crash behavior on Windows; validate the installer/uninstaller, original-user launch, HKCU proxy cleanup, and Task Manager autostart state with a real disposable desktop.
3. Validate Linux installation through polkit/systemd and autostart through a real desktop parser. The ownership tests use injected metadata to test otherwise root-only path combinations without privileged host changes.
4. macOS native compilation, Android Gradle/JVM/device tests, actual network transitions, proxy routing, and throughput/latency benchmarking were not completed here. The fork currently advertises Windows support; inherited Linux/macOS naming and packaging need platform acceptance tests before a broader support claim.
5. Inventory-only platform/window/editor/tooling files and opaque binary assets remain explicit review gaps in the coverage ledger. In particular, `windows/EnableLoopback.exe` was inventoried as a binary, not audited as source.

## Primary references

- [Rust `std::process::Child` ownership and drop behavior](https://doc.rust-lang.org/std/process/struct.Child.html).
- [Windows `CreateProcessW` executable-name and command-line rules](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw).
- [Desktop Entry command quoting and field codes](https://specifications.freedesktop.org/desktop-entry/latest/exec-variables.html).
- [systemd service command syntax](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html).
- [Dart build hooks and user defines](https://dart.dev/tools/hooks).
