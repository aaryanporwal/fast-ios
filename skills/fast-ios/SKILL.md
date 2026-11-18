---
name: fast-ios
description: Get light iOS simulators (about a third of the memory) from fast-ios. Use when building, running or testing an iOS app in the Simulator (xcodebuild, simctl, XCUITest, Expo or React Native iOS), when simulators use too much memory or start slowly, when running several simulators in parallel, or when a feature stops working on a simulator that fast-ios made light.
---

# fast-ios

fast-ios turns off the simulator services an app does not need. A simulator
is **light** when those services are off and **full** when every service
runs, as Xcode sets it up. A full iPhone simulator runs about 280 processes
and 2.8 GB; light for one real app, about 90 and 0.8 GB. Use these two
words, light and full, when you report to the user: they are the words the
user sees in the fast-ios app and command.

With no app known, a simulator gets the general light set (167 of 173
optional services off). An app's needs are added when it is installed or
run. A service comes back when an app needs it.

Prefer the CLI with `--json`; the same commands are MCP tools when the
`fast-ios` MCP server is connected. Errors are JSON too
(`{"error": {"code", "message"}}`). Exit codes: 0 ok, 1 failed, 2 refused
for memory or queue (try later), 64 bad arguments.
`fast-ios <command> --help` shows options and examples; `fast-ios doctor`
explains a broken setup. Some JSON field names come from older words:
`"slim": true` means light.

## The one rule

Never run `fast-ios on` or `fast-ios off` with no simulator: they change
every simulator on the Mac and are the user's switch. Never make light
(`slim`), make full (`off <simulator>`), restart, shut down or delete a
simulator you did not get from fast-ios or create in this task. Someone
else, or another agent, may be using it, and `slim` and `off` restart a
running simulator.

## Get a simulator: `run` or `lease`

- **`run`** when you run the user's app. It finds the build, gets a light
  simulator from the shared pool, installs and launches the app, and
  returns the UDID.
- **`lease`** when you install and test with your own tools
  (`xcodebuild test`, `simctl install`). It only hands over a light,
  running simulator.
- **`release`** after either, when you are done.

```bash
UDID=$(fast-ios run --app path/to/.app-or-project-folder --json | jq -r .udid)
# or: UDID=$(fast-ios lease --app path/to/.app --ttl 30m --json | jq -r .udid)
# … test on $UDID …
fast-ios release "$UDID" --json
```

- With `--json`, `run` opens no Simulator window. Without `--app`, `run`
  uses the newest simulator build of the project in the current folder and
  names it on stderr. `--url` opens a deep link after launch.
- A free running pool simulator comes back in seconds. A new one is copied
  from a light template and took about 12 s to the app running in the
  benchmark; up to 1 to 2 minutes on a busy Mac.
- After a `release`, the simulator keeps running, so the next `run` of the
  same app only installs and launches (about 2 s).
- The simulator is yours until `release`, until `--ttl` passes (30 min), or
  until your process exits, so a crashed agent does not hold a simulator.
  While it is yours, make it light for another app, install and test on it
  freely, but never delete it.
- When the Mac is short on memory, `run` and `lease` wait in a queue and
  say why. After `--timeout` they answer `"status": "refused"` with `reason`
  and `detail`, exit code 2. Do not start a simulator yourself to get
  around a refusal: tell the user, wait, or release one you hold.
  `--max-pressure warning` lets a new simulator start under memory pressure
  "warning"; ask the user first.
- `leases --json` shows who holds what.

## Skip the compile when native code is unchanged

Before you compile the app in a worktree, run `run` from the project folder
with `--build "<the build command>"`. If another agent already built the
same native app, fast-ios installs the stored one and does not run your
command. If one is building it now, `run` waits for that build.

```bash
fast-ios run --build "xcodebuild -workspace ios/App.xcworkspace -scheme App -destination 'generic/platform=iOS Simulator' -derivedDataPath build build" --json
```

- `appCache.status` in the result: `hit` (reused), `built` (you built and
  stored it), `waited` (another agent built it), `miss` (no build ran).
- Expo projects match on native inputs only: a JavaScript change still
  reuses the app; start Metro as usual. Other projects match only identical
  sources.
- `fast-ios apps why . --json` says which inputs differ. Pass `--variant
  <text>` when your build command sets something the files do not show (a
  scheme, `APP_VARIANT=...`), so different builds never share an app.

## Or create your own

When you need a device type or runtime the pool cannot give:

```bash
# Pick the device type and runtime from `xcrun simctl list devicetypes` and `xcrun simctl list runtimes`.
UDID=$(xcrun simctl create agent-sim com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0)
fast-ios slim "$UDID" --app path/to/.app --boot --json        # make it light for the app, then start it
# … build, install, test …
xcrun simctl delete "$UDID"                                    # only because you created it
```

`slim` on a stopped simulator is instant; it starts light. On a running one
it restarts it (30 s to 3 min). With no build yet, use `--full` (every
optional service off) and run `slim` again with `--app` after the first
build. `--app` takes a `.app`, a DerivedData folder, `Build/Products`, or
the project folder (the newest `*-iphonesimulator/*.app` wins).

## See a UI change

```bash
fast-ios shot --app path/to/.app --udid "$UDID" --wait "Sign in" --max-width 400 --grant photos --json
```

One call installs the app if the build changed, grants `--grant`
permissions, relaunches it, opens `--url` if given, waits, and returns
`screenshot` (a PNG path: open it and look) and `tree` (one accessibility
element per line, frames in points; `pixelsPerPoint` maps them onto the PNG).
Always pass `--udid` with a simulator you got from fast-ios or created:
without it, `shot` may start and make light a stopped simulator.
`--wait <text>` waits for that text, which beats waiting for a stable screen
when the app shows a splash. `--max-width 400` keeps the PNG small enough to
read cheaply (47 KB instead of 149 KB in the benchmark). The first tree on a
simulator starts a runner that stays up for 5 minutes, so later trees take
about a second. The tree needs a simulator in the normal set (no `--set`);
with `--set` you get the screenshot and `treeStatus: "unavailable"`.
`--no-tree` skips it.

`--grant` (also on `run`) answers these prompts in advance: photos,
photos-add, contacts, contacts-limited, calendar, reminders, location,
location-always, microphone, media-library, motion, siri, or all.
Notifications, camera, speech recognition and tracking cannot be granted
this way: the app still asks, so tap the alert or skip the request in test
builds. Bluetooth needs no grant on the simulator. On iOS 26.5, `photos`
(full library) is still asked; `photos-add` works.

## Check what will be off

`fast-ios profile <app> --json` shows `profile.keep` (label -> reasons) and
`profile.disable`, without changing anything. `catalog --json` lists every
service by category (`id`, `name`) with its `downside`: what stops working
while it is off.

## When something breaks

The light set only sees what the app declares and links. Typical misses: a
test opens Maps, Settings, Safari, the share sheet target app, or relies on
push, iCloud or StoreKit when the app reaches them some other way.

0. Self-repair first. When an app calls a service that is off, fast-ios
   turns it back on within a few seconds, with no restart, and keeps it on
   for that app. The call that failed is not repeated: do that step again.
   Proved for photos and contacts on iOS 27.0; push is not turned back on
   this way (keep `com.apple.apsd`). While the user has fast-ios on, this
   happens by itself. Otherwise run `heal` while you repeat the failing
   step: CLI `fast-ios heal <udid> --app <bundle id or .app> --seconds 120
   --json &`, repeat the step, then `fast-ios repairs --json`; MCP `heal`
   with `simulator`, `app` and `seconds`. If nothing is repaired, go on.
1. Find the category whose `downside` matches the symptom in `catalog`.
2. Ask the user, then keep it:
   `fast-ios slim <udid> --app <app> --keep widgets --json`
   (`--keep` takes a category ID such as `widgets`, its full name, or one
   service label such as `com.apple.apsd`; it repeats; `run` takes it too;
   the MCP `slim` tool takes `keep: [...]`).
3. Still broken: `fast-ios off <udid> --json` makes that simulator full. If
   the bug is gone on a full simulator, a turned-off service caused it;
   report which.

Services that starting the simulator, app launch, install, keychain,
location, logging and networking depend on are never turned off (`catalog`
lists them under `neverDisabled`).

## Measure

`fast-ios measure <udid> --json` gives `processCount` and `totalBytes`
(memory of every process in the simulator, added up) for a running
simulator. `status` shows a cheaper estimate for every running one.

## Separate sets of simulators

Every command takes `--set <path>` (MCP: `deviceSet`) for a separate
CoreSimulator device set, such as one made with `xcrun simctl --set <path>
create …`. Use one when other tools watch the normal set. The `shot` tree
does not work there.

## Install this skill and the MCP server

For Claude Code, run in any folder:

```bash
claude mcp add --scope user fast-ios -- fast-ios mcp
mkdir -p ~/.claude/skills/fast-ios && curl -fsSL https://raw.githubusercontent.com/aaryanporwal/fast-ios/main/skills/fast-ios/SKILL.md -o ~/.claude/skills/fast-ios/SKILL.md
```

Then start a new session. `claude mcp get fast-ios` shows the server.
