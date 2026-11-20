# Flutter included-build plugin repositories

The Android audit build at commit `f5140216` failed while configuring Flutter
3.50.0's included Gradle build, before app source compilation. Its plugin
classpath searched only the Gradle Plugin Portal for Kotlin 2.4.10's stdlib,
plugin API and BOM. The app's own `pluginManagement.repositories` do not
configure this separate included build. This failure does **not** establish
that Kotlin 2.4.10 is unpublished.

`flutter_repositories.init.gradle` runs before settings evaluation and supplies
Maven Central, Google Maven and the Plugin Portal to the Flutter included
build's **plugin** repository list. It only acts when the settings directory
equals `FLUTTER_ROOT/packages/flutter_tools/gradle` after canonicalization.
It does not change dependency versions, edit the Flutter SDK, replace project
dependency repositories, or install anything in the user's global Gradle home.

## Reuse locally

Set `FLUTTER_ROOT` to the SDK used by `flutter`. From this repository's root,
use a disposable Gradle home so other projects and existing user settings are
unaffected:

```sh
export FLUTTER_ROOT=/absolute/path/to/flutter
export GRADLE_USER_HOME="$(mktemp -d)"
mkdir -p "$GRADLE_USER_HOME/init.d"
cp tool/gradle/flutter_repositories.init.gradle "$GRADLE_USER_HOME/init.d/"
flutter build apk --debug --target-platform android-arm64
```

Keep that directory while building; Gradle stores downloaded dependencies and
its wrapper there. After stopping Gradle processes and finishing the build,
the disposable directory can be removed. Do not point this procedure at an
existing global Gradle user home. On Windows, use the same environment variables
and copy the script to a new dedicated directory's `init.d` subdirectory.

For direct Gradle calls the same script can instead be passed with
`--init-script`, while keeping `FLUTTER_ROOT` set. Gradle applies init scripts
to included builds as well. Flutter CLI does not forward arbitrary Gradle
arguments, which is why its documented command uses a dedicated Gradle home.

## Verification and limits

The audit workflow uses this script from a job-scoped temporary Gradle home,
checks the actual Kotlin POM endpoints on Maven Central, and then runs the real
APK build and Android unit tests. This document records the diagnosed resolver
context and the proposed fix; successful APK compilation must be confirmed by
the current PR workflow. It is not a replacement for Android device tests.

Primary references:

- [Flutter 3.50.0 included settings](https://github.com/flutter/flutter/blob/3.50.0/packages/flutter_tools/gradle/settings.gradle.kts)
- [Flutter 3.50.0 plugin build](https://github.com/flutter/flutter/blob/3.50.0/packages/flutter_tools/gradle/build.gradle.kts)
- [Gradle initialization scripts](https://docs.gradle.org/current/userguide/init_scripts.html)
- [Gradle build lifecycle and beforeSettings](https://docs.gradle.org/current/userguide/build_lifecycle.html)
- [Gradle init scripts include composite builds](https://docs.gradle.org/8.0/release-notes.html#init-scripts-are-applied-to-buildsrc)
- [Observed Android failure](https://github.com/xydadada/vps2vpn-client/actions/runs/44721647657/job/136238759086)
