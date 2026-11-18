#!/bin/bash
# Records the CLI colour stills (docs/design/cli/*.png) on a dark and a light
# theme, away from your real simulators:
#   - fast-ios from this checkout in /tmp/fastios-stills/bin
#   - a private device set /tmp/fastios-stills/sims with one iPhone 18 Pro
#   - a helper under the throwaway label dev.fast-ios.stills (never dev.fast-ios.auto)
# Everything is removed at the end. Run from the repository root:
#   docs/design/cli/stills.sh
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
work=/tmp/fastios-stills
export FASTIOS_DEVICE_SET=$work/sims FASTIOS_STATE_DIR=$work/state FASTIOS_AGENT_LABEL=dev.fast-ios.stills

cleanup() {
  [ -x "$work/bin/fast-ios" ] && "$work/bin/fast-ios" off >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)/dev.fast-ios.stills" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/dev.fast-ios.stills.plist"
  if [ -d "$work/sims" ]; then
    for u in $(xcrun simctl --set "$work/sims" list devices -j | /usr/bin/python3 -c 'import json,sys; [print(d["udid"]) for v in json.load(sys.stdin)["devices"].values() for d in v]'); do
      xcrun simctl --set "$work/sims" shutdown "$u" 2>/dev/null || true
      xcrun simctl --set "$work/sims" delete "$u"
    done
  fi
  rm -rf "$work"
}
trap cleanup EXIT

rm -rf "$work"; mkdir -p "$work/bin" "$work/sims" "$work/state"
(cd "$repo" && swift build -c release >/dev/null)
cp "$repo/.build/release/fast-ios" "$work/bin/fast-ios"
touch "$work/state/welcomed"
udid=$(xcrun simctl --set "$work/sims" create "iPhone 18 Pro" \
  com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0)
xcrun simctl --set "$work/sims" create "iPad Air" \
  com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4 com.apple.CoreSimulator.SimRuntime.iOS-27-0 >/dev/null || true
"$work/bin/fast-ios" on >/dev/null
xcrun simctl --set "$work/sims" bootstatus "$udid" -b >/dev/null
echo "Booted light; settling 60 s…"
sleep 60

for theme in dark light; do
  name="Catppuccin Mocha"; [ "$theme" = light ] && name="Github"
  sed -e "s/@THEME@/$name/" -e "s/@SUFFIX@/$theme/g" "$repo/docs/design/cli/stills.tape" > "$work/stills-$theme.tape"
  (cd "$repo" && vhs "$work/stills-$theme.tape")
done
echo "Stills in docs/design/cli/"
