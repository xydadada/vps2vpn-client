#!/usr/bin/env bash
# The control for android-e2e.sh: brings up a tunnel shaped like the app's
# (198.18.0.1/30, DNS 198.18.0.2, all IPv4 but 10/8) that only drops what it
# reads, sends some traffic into it, then checks the phone stays alive.
# usage: android-probe.sh <probe apk> <mtu> [out dir] [proxy: also set the VPN HTTP proxy]
set -uo pipefail
[ -n "${GITHUB_ACTIONS:-}" ] || { echo 'CI only: this drives an emulator' >&2; exit 2; }
APK=$1
MTU=$2
OUT=${3:-android-probe}
PROXY=${4:-}
PKG=com.vps2vpn.probe
mkdir -p "$OUT"
fails=0
check() {
  if eval "$1"; then echo "PASS  $2"; else echo "FAIL  $2"; fails=$((fails + 1)); fi
}
alive() { [ "$(timeout 5 adb shell echo ok 2>/dev/null | tr -d '\r')" = ok ]; }
vpn_up() { timeout 5 adb shell ip -o link 2>/dev/null | grep -qE '^[0-9]+: tun[0-9]+[:@]'; }

adb wait-for-device
adb logcat -v time > "$OUT/logcat.txt" 2>&1 &
logcat=$!
(
  while sleep 2; do
    echo "$(date +%T) guest=$(alive && echo ok || echo silent) qemu=$(pgrep -f qemu-system | head -1)"
  done
) > "$OUT/liveness.log" 2>&1 &
watch=$!
trap 'cp -r /tmp/android-runner "$OUT/runner" 2>/dev/null; kill $logcat $watch 2>/dev/null' EXIT

check 'adb install -r -g "$APK" > "$OUT/install.log" 2>&1' 'probe installs'
adb shell appops set "$PKG" ACTIVATE_VPN allow
adb shell am start -n "$PKG/.Main" --ei mtu "$MTU" --ez proxy "$([ "$PROXY" = proxy ] && echo true || echo false)" > /dev/null
for _ in $(seq 1 10); do vpn_up && break; sleep 2; done
check vpn_up "the probe tunnel is up (mtu $MTU)"
adb shell ip addr show tun0 > "$OUT/tun0.txt" 2>&1
adb shell ip route show table all > "$OUT/routes.txt" 2>&1

for i in 1 2 3 4 5; do
  timeout 10 adb shell "printf 'GET / HTTP/1.0\r\n\r\n' | nc -w 3 1.1.1.1 80" > /dev/null 2>&1
  timeout 10 adb shell ping -c 2 -W 1 8.8.8.8 > /dev/null 2>&1
  timeout 10 adb shell "nc -w 3 www.gstatic.com 80 < /dev/null" > /dev/null 2>&1
done
silent=0
for _ in $(seq 1 30); do
  alive || silent=$((silent + 1))
  sleep 3
done
check '[ "$silent" -eq 0 ]' "the phone answered adb for 90 s with the tunnel up (silent $silent of 30)"
check vpn_up 'the probe tunnel is still up'
check 'grep -q "vpnprobe.*packets [0-9]* last" "$OUT/logcat.txt"' 'packets reached the probe tunnel'
grep 'vpnprobe' "$OUT/logcat.txt" | tail -5

if [ "$fails" -gt 0 ]; then echo; echo "$fails check(s) failed"; exit 1; fi
echo; echo 'all checks passed'
