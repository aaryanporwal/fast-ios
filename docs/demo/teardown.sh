#!/bin/bash
# Undoes prepare.sh and the recording: turns the demo helper off (label
# dev.fast-ios.demo), deletes every simulator in /tmp/demo/sims (all made
# for the demo), and removes /tmp/demo. Never touches dev.fast-ios.auto or
# any other simulator.
set -uo pipefail
demo=/tmp/demo
export FASTIOS_DEVICE_SET=$demo/sims FASTIOS_STATE_DIR=$demo/state FASTIOS_AGENT_LABEL=dev.fast-ios.demo
[ -x "$demo/bin/fast-ios" ] && "$demo/bin/fast-ios" off >/dev/null
launchctl bootout "gui/$(id -u)/dev.fast-ios.demo" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/dev.fast-ios.demo.plist"
if [ -d "$demo/sims" ]; then
  for u in $(xcrun simctl --set "$demo/sims" list devices | grep -oE '\([0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}\)' | tr -d '()' | sort -u); do
    xcrun simctl --set "$demo/sims" shutdown "$u" 2>/dev/null
    xcrun simctl --set "$demo/sims" delete "$u"
    rm -rf "/private/var/tmp/com.apple.CoreSimulator.SimDevice.$u"
  done
fi
rm -rf "$demo"
echo "Demo removed."
