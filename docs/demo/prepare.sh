#!/bin/bash
# Sets up the README demo in /tmp/demo, away from your real simulators:
#   - fast-ios from this checkout (release build) in /tmp/demo/bin
#   - a private device set /tmp/demo/sims and state folder /tmp/demo/state
#   - a full "iPhone 18 Pro" simulator, started and left 3 minutes to settle,
#     so the first frame shows a full simulator's real memory
# The helper `fast-ios on` installs in the recording uses the label
# dev.fast-ios.demo and only watches /tmp/demo/sims; teardown.sh removes it.
# Run from the repository root: docs/demo/prepare.sh
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
demo=/tmp/demo
export FASTIOS_DEVICE_SET=$demo/sims FASTIOS_STATE_DIR=$demo/state FASTIOS_AGENT_LABEL=dev.fast-ios.demo

if [ -e "$demo" ]; then echo "$demo exists: run docs/demo/teardown.sh first." >&2; exit 1; fi
mkdir -p "$demo/bin" "$demo/sims" "$demo/state"
(cd "$repo" && swift build -c release >/dev/null)
cp "$repo/.build/release/fast-ios" "$demo/bin/fast-ios"
touch "$demo/state/welcomed"   # the one-time welcome text is not part of the demo

udid=$(xcrun simctl --set "$demo/sims" create "iPhone 18 Pro" \
  com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0)
xcrun simctl --set "$demo/sims" bootstatus "$udid" -b >/dev/null
echo "Full simulator $udid started; waiting 3 minutes for its memory to settle."
sleep 180
echo "Ready. Record with: vhs docs/demo/demo.tape"
