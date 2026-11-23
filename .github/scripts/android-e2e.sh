#!/usr/bin/env bash
# vps2vpn's APK on a CI emulator: install, import a subscription whose only
# proxy is a CI-local upstream, connect the VPN and check traffic goes through it.
# usage: android-e2e.sh <apk> [out dir] [package]
set -uo pipefail
[ -n "${GITHUB_ACTIONS:-}" ] || { echo 'CI only: this drives an emulator' >&2; exit 2; }
APK=$1
OUT=${2:-android-e2e}
PKG=${3:-com.vps2vpn.client}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
fails=0
check() {
  if eval "$1"; then echo "PASS  $2"; else echo "FAIL  $2"; fails=$((fails + 1)); fi
}

work=$(mktemp -d)
log="$OUT/upstream.log"
: > "$log"
mkdir -p "$work/sub"
cat > "$work/sub/sub.yaml" <<'EOF'
mixed-port: 7890
mode: rule
proxies:
  - {name: ci-upstream, type: http, server: 10.0.2.2, port: 18080}
proxy-groups:
  - {name: Proxy, type: select, proxies: [ci-upstream]}
rules:
  - MATCH,Proxy
EOF
python3 -I "$HERE/coexist_upstream.py" "$log" 18080 &
up=$!
python3 -I -m http.server --bind 127.0.0.1 --directory "$work/sub" 18000 > "$OUT/sub-server.log" 2>&1 &
sub=$!
trap 'kill $up $sub 2>/dev/null' EXIT
sleep 2

shot() { adb exec-out screencap -p > "$OUT/$1.png" 2>/dev/null; }
dump() {
  adb shell uiautomator dump /sdcard/ui.xml > /dev/null 2>&1
  adb shell cat /sdcard/ui.xml 2>/dev/null
}
screen() {
  dump | python3 -I -c 'import re, sys
print(" | ".join(t for t in re.findall(r" (?:text|content-desc)=\"([^\"]+)\"", sys.stdin.read())))'
}
tap() {
  local at
  at=$(dump | python3 -I -c 'import re, sys
pattern = re.compile(sys.argv[1], re.I)
for node in re.findall(r"<node [^>]*>", sys.stdin.read()):
    label = " ".join(re.findall(r" (?:text|content-desc)=\"([^\"]*)\"", node))
    if pattern.search(label):
        x1, y1, x2, y2 = map(int, re.search(r"bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", node).groups())
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break' "$1")
  [ -n "$at" ] || return 1
  adb shell input tap $at
}
wait_tap() {
  for _ in $(seq 1 "${2:-15}"); do
    tap "$1" && return 0
    sleep 2
  done
  return 1
}
through_vpn() {
  local before reply
  before=$(wc -l < "$log")
  reply=$(adb shell "printf 'GET /generate_204 HTTP/1.1\r\nHost: www.gstatic.com\r\nConnection: close\r\n\r\n' | nc -w 15 www.gstatic.com 80" 2>&1 | head -1)
  sleep 2
  check '[[ "$reply" == *" 204"* ]]' "$1: a request from the phone answers 204 (got: ${reply%%$'\r'})"
  check '[ "$(wc -l < "$log")" -gt "$before" ]' "$1: it went out through the CI upstream proxy"
}
# tun0 and the like; the emulator always has an unrelated tunl0.
vpn_up() { adb shell ip -o link 2>/dev/null | grep -qE '^[0-9]+: tun[0-9]+[:@]'; }
front() { adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1; }

adb wait-for-device
check 'adb install -r -g "$APK" > "$OUT/install.log" 2>&1' 'APK installs'
check 'adb shell pm list packages | grep -q "package:$PKG\$"' "installed as $PKG"
adb shell appops set "$PKG" ACTIVATE_VPN allow
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
sleep 15
shot first-start
echo "screen: $(screen)"
# The disclaimer's Agree asks for its statement ticked before Confirm.
if wait_tap '^(agree|同意)$' 5; then
  sleep 3
  wait_tap 'I have read and understand this statement|我已阅读并理解此声明' 5 || echo 'no statement to tick'
  sleep 1
  wait_tap '^(confirm|确认|确定)$' 5 || echo 'no confirm button after the statement'
  sleep 5
fi
check 'adb shell pidof "$PKG" > /dev/null' 'the app is running after the first start'
shot after-disclaimer
echo "screen: $(screen)"

adb shell am start -a android.intent.action.VIEW \
  -d "'vps2vpn://install-config?url=http%3A%2F%2F10.0.2.2%3A18000%2Fsub.yaml'" "$PKG" > /dev/null
sleep 4
echo "screen: $(screen)"
wait_tap '^(ok|confirm|add|确定|确认|添加)$' 5 || true
check 'for _ in $(seq 1 20); do grep -q "GET /sub.yaml" "$OUT/sub-server.log" && break; sleep 1; done; grep -q "GET /sub.yaml" "$OUT/sub-server.log"' 'the app downloaded the subscription'
sleep 5
front
sleep 3
shot imported
echo "screen: $(screen)"

for round in 1 2 3; do
  wait_tap '^(connect|连接|tap to connect|点击连接|启动|start)$' 5 || echo "no connect button found"
  for _ in $(seq 1 15); do vpn_up && break; sleep 2; done
  shot "connected-$round"
  echo "screen: $(screen)"
  check vpn_up "round $round: the VPN is up"
  through_vpn "round $round"
  wait_tap '^(disconnect|断开|断开连接|stop|停止)$' 5 || tap '^(connected|已连接)$' || echo "no disconnect button found"
  for _ in $(seq 1 10); do vpn_up || break; sleep 2; done
  check '! vpn_up' "round $round: the VPN is down after disconnecting"
done

check 'adb uninstall "$PKG" > /dev/null' 'APK uninstalls'
if [ "$fails" -gt 0 ]; then echo; echo "$fails check(s) failed"; exit 1; fi
echo; echo 'all checks passed'
