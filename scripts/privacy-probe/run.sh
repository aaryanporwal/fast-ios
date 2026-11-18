#!/usr/bin/env bash
# Which permission prompts does `simctl privacy grant all` answer in advance?
# Builds the probe app (main.swift), runs it on a throwaway simulator in a new
# private device set, before and after the grant, and prints each status.
# 0 = not determined (the app would still prompt). Deletes everything after.
#
# Usage: scripts/privacy-probe/run.sh [runtime id] [device type]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
runtime=${1:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}
devtype=${2:-com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro}
bundle=dev.fastios.privacyprobe
work=$(mktemp -d "${TMPDIR:-/tmp}/fast-ios-privacy.XXXXXX")
set_dir=$work/devices
mkdir -p "$set_dir"
sim() { xcrun simctl --set "$set_dir" "$@"; }
udid=""
cleanup() {
  if [[ -n $udid ]]; then sim shutdown "$udid" >/dev/null 2>&1 || true; sim delete "$udid" >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

app=$work/PrivacyProbe.app
mkdir -p "$app"
cp "$here/Info.plist" "$app/Info.plist"
xcrun -sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios17.0-simulator \
  "$here/main.swift" -o "$app/PrivacyProbe"
codesign -s - "$app" >/dev/null 2>&1

udid=$(sim create privacy-probe "$devtype" "$runtime")
sim bootstatus "$udid" -b >/dev/null
sim install "$udid" "$app"

probe() {
  local data
  sim launch --terminate-running-process "$udid" "$bundle" >/dev/null
  data=$(sim get_app_container "$udid" "$bundle" data)
  for _ in $(seq 1 50); do [[ -f $data/Documents/privacy.json ]] && break; sleep 0.2; done
  cat "$data/Documents/privacy.json"
  rm -f "$data/Documents/privacy.json"
}

before=$(probe)
sim privacy "$udid" grant all "$bundle"
after_all=$(probe)
sim privacy "$udid" reset all "$bundle"
for s in calendar contacts location photos photos-add media-library microphone motion reminders siri; do
  sim privacy "$udid" grant "$s" "$bundle"
done
after_each=$(probe)
echo "runtime: $runtime   (0 = not determined: the app would prompt; -1 = no answer in 5 s)"
printf '%-15s %8s %10s %10s\n' service before "grant all" "each one"
for k in $(echo "$before" | jq -r 'keys[]'); do
  printf '%-15s %8s %10s %10s\n' "$k" "$(echo "$before" | jq ".\"$k\"")" \
    "$(echo "$after_all" | jq ".\"$k\"")" "$(echo "$after_each" | jq ".\"$k\"")"
done
