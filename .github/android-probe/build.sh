#!/usr/bin/env bash
# Builds the probe APK with the SDK's own tools (no Gradle): build.sh <out.apk>
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(realpath -m "$1")
sdk=${ANDROID_HOME:?}
platform=$(ls -d "$sdk"/platforms/android-* | sort -V | tail -1)
tools=$(ls -d "$sdk"/build-tools/* | sort -V | tail -1)
echo "platform $(basename "$platform"), build-tools $(basename "$tools")"
work=$(mktemp -d)
"$tools/aapt2" link --manifest "$HERE/AndroidManifest.xml" -I "$platform/android.jar" -o "$work/base.apk"
javac --release 11 -classpath "$platform/android.jar" -d "$work/classes" $(find "$HERE/src" -name '*.java')
mkdir "$work/dex"
"$tools/d8" --release --min-api 24 --lib "$platform/android.jar" --output "$work/dex" $(find "$work/classes" -name '*.class')
(cd "$work/dex" && zip -q "$work/base.apk" classes.dex)
"$tools/zipalign" -f 4 "$work/base.apk" "$work/aligned.apk"
keytool -genkeypair -keystore "$work/probe.jks" -storepass android -keypass android -alias probe \
  -keyalg RSA -keysize 2048 -dname CN=probe -validity 2 -noprompt > /dev/null 2>&1
"$tools/apksigner" sign --ks "$work/probe.jks" --ks-pass pass:android --out "$OUT" "$work/aligned.apk"
ls -l "$OUT"
