#!/usr/bin/env bash
# Runs the real fast-ios flow on a throwaway simulator: run, shot, heal,
# release, off. Everything happens in a new private CoreSimulator device set
# and a new private state folder, so no existing simulator, lease or profile
# is seen or touched. Every simulator in that set was created by this run,
# and the script checks each UDID against that list before it acts on it.
#
# Usage: scripts/integration.sh <path to a simulator .app> [path to fast-ios]
# Needs Xcode with an iOS simulator runtime. Takes 1–3 minutes and boots one
# simulator. The app must have a scene manifest (iOS 27 kills apps without one).
set -euo pipefail

app=${1:?usage: scripts/integration.sh <simulator .app> [fast-ios binary]}
repo=$(cd "$(dirname "$0")/.." && pwd)
bin=${2:-$repo/.build/debug/fast-ios}
[[ -d $app ]] || { echo "integration: $app is not a .app folder" >&2; exit 64; }
[[ -x $bin ]] || { echo "integration: $bin not found; run swift build first" >&2; exit 64; }
command -v jq >/dev/null || { echo "integration: needs jq" >&2; exit 64; }

work=$(mktemp -d "${TMPDIR:-/tmp}/fast-ios-integration.XXXXXX")
set_dir=$work/devices          # private device set, empty at start
export FASTIOS_STATE_DIR=$work/state   # private leases, profiles, heal store
mkdir -p "$set_dir" "$FASTIOS_STATE_DIR"
created=()                     # UDIDs this run created; the only ones it may touch
set_was_empty=0

fio() { "$bin" --set "$set_dir" "$@"; }
step() { printf '\n== %s\n' "$*"; }
fail() { echo "integration: FAIL: $*" >&2; exit 1; }

udids_in_set() { xcrun simctl --set "$set_dir" list devices -j | jq -r '.devices[][].udid'; }

is_owned() {
  local u=$1 c
  for c in "${created[@]:-}"; do [[ -n $c && $c == "$u" ]] && return 0; done
  return 1
}
# Refuses any UDID this run did not create.
owned() { is_owned "$1" || fail "refusing to touch $1: this run did not create it"; }

cleanup() {
  local status=$? u
  step "cleanup"
  # If `run` failed before the script recorded what it created, everything in
  # the set is still ours, but only if the set was checked empty at the start.
  if [[ ${#created[@]} -eq 0 && $set_was_empty == 1 ]]; then
    # shellcheck disable=SC2207
    created=($(udids_in_set 2>/dev/null))
  fi
  for u in $(udids_in_set 2>/dev/null); do
    is_owned "$u" || { echo "skipping $u: not created by this run"; continue; }
    xcrun simctl --set "$set_dir" shutdown "$u" >/dev/null 2>&1 || true
    xcrun simctl --set "$set_dir" delete "$u" >/dev/null 2>&1 || true
    rm -rf "/private/var/tmp/com.apple.CoreSimulator.SimDevice.$u"
    echo "deleted $u"
  done
  rm -rf "$work"
  [[ $status -eq 0 ]] && echo "integration: PASS" || echo "integration: FAIL (exit $status)"
}
trap cleanup EXIT

[[ -z $(udids_in_set) ]] || fail "the new device set is not empty"
set_was_empty=1

step "run: lease a slim simulator, install and launch"
out=$(fio run --app "$app" --json)
echo "$out" | jq '{udid, simulatorSource, launched, bundleIdentifier, seconds}'
udid=$(echo "$out" | jq -r .udid)
bundle=$(echo "$out" | jq -r .bundleIdentifier)
# The set was empty, so whatever is in it now, fast-ios created during this run.
# shellcheck disable=SC2207 # UDIDs have no spaces; bash 3.2 has no mapfile
created=($(udids_in_set))
owned "$udid"
[[ $(echo "$out" | jq -r .launched) == true ]] || fail "run did not launch the app"
xcrun simctl --set "$set_dir" list devices | grep -q "$udid) (Booted)" || fail "$udid is not booted"
disabled=$(plutil -convert json -o - "/private/var/tmp/com.apple.CoreSimulator.SimDevice.$udid/disabled.plist" | jq '[.[] | select(. == true)] | length')
(( disabled > 0 )) || fail "the simulator is not slim"
echo "slim: $disabled services disabled"

step "shot: screenshot (the tree needs the default set, so it is skipped here)"
shot=$(fio shot --app "$app" --udid "$udid" --no-tree --wait 8 --out "$work/shots" --json)
echo "$shot" | jq '{installed, screenStable, treeStatus, screenshot, totalMs}'
png=$(echo "$shot" | jq -r .screenshot)
[[ $(echo "$shot" | jq -r .installed) == false ]] || fail "shot reinstalled an unchanged build"
[[ $(head -c 8 "$png" | xxd -p) == 89504e470d0a1a0a ]] || fail "$png is not a PNG"

step "heal: follow the app's log for 8 s"
owned "$udid"
fio heal "$udid" --app "$app" --seconds 8 --json > "$work/heal.ndjson"
jq -c '{event, label, why}' "$work/heal.ndjson"
jq -e 'select(.event == "healing")' "$work/heal.ndjson" >/dev/null || fail "heal never started"
jq -e 'select(.event == "stopped")' "$work/heal.ndjson" >/dev/null || fail "heal did not stop cleanly"

step "release"
owned "$udid"
fio release "$udid" --json | jq '{udid, status}'
[[ $(fio leases --json | jq --arg u "$udid" '[.leases[] | select(.udid == $u)] | length') == 0 ]] || fail "lease still held"

step "off: restore stock"
owned "$udid"
off=$(fio off "$udid" --json)
echo "$off" | jq '{reenabled: (.reenabled | length), alreadyStock, booted}'
after=$(plutil -convert json -o - "/private/var/tmp/com.apple.CoreSimulator.SimDevice.$udid/disabled.plist" 2>/dev/null \
  | jq '[.[] | select(. == true)] | length' || echo 0)
[[ $after == 0 ]] || fail "$after services still disabled after off"
echo "app $bundle on $udid: run, shot, heal, release, off all passed"
