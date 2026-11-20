#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

group() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::group::$1"; else echo "==> $1"; fi
}

endgroup() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::endgroup::"; fi
}

shopt -s nullglob globstar
manifests=(plugins/*/pubspec.yaml)

if [[ ${#manifests[@]} -eq 0 ]]; then
  echo "no plugin packages found under plugins/" >&2
  exit 1
fi

analyzed=0
tested=0

for manifest in "${manifests[@]}"; do
  package="$(dirname "$manifest")"
  tests=("$package"/test/**/*_test.dart)
  group "$package"
  (
    cd "$package"
    flutter pub get
    flutter analyze --no-fatal-infos
    if ((${#tests[@]})); then
      flutter test --reporter expanded
    else
      echo "no tests in $package"
    fi
  )
  analyzed=$((analyzed + 1))
  if ((${#tests[@]})); then
    tested=$((tested + 1))
  fi
  endgroup
done

echo "analyzed $analyzed plugin package(s), $tested with tests"
