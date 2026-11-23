#!/usr/bin/env bash
# One change to the source before an experimental APK is built, to find what
# freezes the emulator once the VPN is up. Never published: android.yaml
# refuses publish with an experiment.
# usage: android-experiment.sh <none|gvisor|system|mixed|addr172|mtu1500>
set -euo pipefail
tun=core/tun/tun.go
vpn=android/service/src/main/java/com/follow/clash/service/VpnService.kt
opts=android/service/src/main/java/com/follow/clash/service/models/VpnOptions.kt
change() {
  local file=$1 from=$2 to=$3
  grep -qF -- "$from" "$file" || { echo "not found in $file: $from" >&2; exit 1; }
  python3 -I - "$file" "$from" "$to" <<'PY'
import sys
path, old, new = sys.argv[1:]
text = open(path, encoding='utf-8').read()
open(path, 'w', encoding='utf-8').write(text.replace(old, new))
PY
  echo "$file: $from -> $to"
}
case "$1" in
  none) ;;
  gvisor | system | mixed)
    change "$tun" 'constant.StackTypeMapping[strings.ToLower(stack)]' "constant.StackTypeMapping[\"$1\"]" ;;
  addr172)
    change "$vpn" '"198.18.0.1/30"' '"172.19.0.1/30"'
    change "$vpn" 'DNS = "198.18.0.2"' 'DNS = "172.19.0.2"' ;;
  mtu1500)
    change "$opts" 'DEFAULT_TUN_MTU = 9000' 'DEFAULT_TUN_MTU = 1500' ;;
  *) echo "unknown experiment: $1" >&2; exit 2 ;;
esac
