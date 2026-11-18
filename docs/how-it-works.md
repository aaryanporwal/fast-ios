# How fast-ios works

Back to the [README](../README.md).

## Light and full

A simulator is **light** when fast-ios has turned off the services it does
not need, and **full** when every service runs, as Xcode sets it up.

**What light means for your app.** With no app known, a simulator gets the
general light set: 167 of the 173 optional services off. Your app's needs
are added when it is installed or run. A service comes back when an app
needs it.

**When an app needs a service that is off.** When an app calls a service
that is off, such as the photo library or contacts, fast-ios turns it back
on within a few seconds, with no restart, and keeps it on for that app. The
call that failed is not repeated for you: do that step again. This is
proved for photos and contacts on iOS 27.0. Push notifications are not
turned back on this way; an app that can receive push keeps them from the
start. Nothing is deleted, and no app data is touched. See [Self-repair](#self-repair-turn-on-what-the-app-calls) below.

## Self-repair: turn on what the app calls

When an app calls a service that is off, such as the photo library or
contacts, fast-ios turns it back on within a few seconds, with no restart,
and keeps it on for that app. The call that failed is not repeated for you:
do that step again. This is proved for photos and contacts on iOS 27.0.
Push notifications are not turned back on this way; an app that can receive
push keeps them from the start.

While fast-ios is on, its background helper does this for every running
light simulator and every app on it; you run nothing. Without `fast-ios on`
(an agent with its own simulator, say), run `heal` yourself:

```bash
fast-ios heal booted --app com.example.myapp --json   # runs until Ctrl-C, or --seconds N
fast-ios repairs --json                               # what was turned back on, and why
```

`heal --app` takes the app's bundle ID or its `.app`. To start leaner,
`slim --strict` keeps only what the app declares (Info.plist keys,
background modes, entitlements, embedded extensions), not every framework a
library links, and lets self-repair add the rest:
`fast-ios slim booted --app MyApp.app --strict`.

`heal` follows the simulator's log for the app's process. When a call fails
with a log line that names a Mach service, heal maps that name to the
launchd label through the runtime's job plists (`MachServices`), checks
that fast-ios turned the label off, runs `launchctl enable` and `bootstrap`
inside the simulator (no restart), and saves the label for that bundle id.
Every later light set for the app keeps it. Each repair is one JSON line:
service, Mach service, the log line, and the time from failure to running.
The MCP tools are `heal` (bounded by `seconds`) and `repairs`.

**Guards.** One attempt per service per cool-down (`--cooldown`, 30 s); at
most `--max-repairs` (10) services per run, then a `cap-reached` event and
no more changes; only catalog services, never the never-disable list; a
failure for a service that is not off is reported as `ignored`, not acted
on.

**What is proved, and what is not.** On iOS 27.0 (15 Nov 2026), with a
test app on a simulator with every optional service off:

- **Photos** (`assetsd`, logged as `com.apple.photos.service`) and
  **contacts** (`contactsd`): the first call failed (0 photos;
  "Communication Error"), heal turned the service on 1.1 to 2.5 s after the
  log line, and the retry worked (6 photos, 6 contacts). Repeated in two
  runs; a repeat call caused no second repair, and `--max-repairs 1` stopped
  the second service.
- **Push** (`apsd`) is not healed. The app asks SpringBoard, and SpringBoard
  logged the failure in one of three runs. It also calls `apsd` on its own
  timer, which would turn push on for apps that never use it. An app that
  can receive push has `aps-environment`, and that keeps `apsd` even with
  `--strict`.
- The app's first call still fails: do the step again after a repair.
- It is a guess that every other service fails this visibly. A client that
  gives up silently, or a service reached without a Mach lookup, is not
  seen. Then use `--keep` or `off`.


## How it works

1. **Read the app.** fast-ios reads `Info.plist` (privacy usage keys,
   `UIBackgroundModes`), the entitlements (from the code signature, and for
   simulator builds from the binary's `__TEXT,__entitlements` section, where
   Xcode puts them), and the system frameworks every binary in the bundle
   links (`otool -L`).
2. **Map to services.** [`CapabilityMap.swift`](../Sources/FastIOSCore/CapabilityMap.swift)
   is a data table. Each row is a trigger, the launchd labels it keeps, and a
   reason. For example: `NSPhotoLibraryUsageDescription` keeps `assetsd` and
   `assetsd.nebulad`; `aps-environment` or `remote-notification` keeps
   `apsd`; associated domains keep `swcd`; linking `StoreKit` keeps
   `storekitd` and Apple Media Services. Every other service in the
   [catalog](../Sources/FastIOSCore/ServiceCatalog+Data.swift) is turned off.
3. **Write the launchd overrides.** `launchd_sim`, the simulator's first
   process, reads
   `/private/var/tmp/com.apple.CoreSimulator.SimDevice.<UDID>/disabled.plist`
   (a flat dict of label to bool) when it starts. fast-ios shuts the
   simulator down if it is running, merges its entries into that file (temp
   file and `rename(2)`, so a half-written file is never read), and starts
   it with `xcrun simctl`. Entries fast-ios does not manage are left as they
   were.
4. **Verify.** After the start it asks launchd (`launchctl print-disabled
   system`) whether every override is active. If a runtime ignored the file,
   it falls back to `launchctl disable` and one more restart.
5. **Watch.** The background helper uses FSEvents on `~/Library/Developer` to
   see new folders in `CoreSimulator/Devices` and `XCTestDevices`, and
   writes the overrides while the new simulator is still stopped. Its first
   start is already light. `fast-ios watch` does the same in a terminal.

No private frameworks: only `xcrun simctl`, `launchctl` inside the
simulator, `xcodebuild` for the `shot` tree, and files on disk.

### Never turned off

`backboardd`, `SpringBoard`, `sharingd`, `assistantd`, `gamed`, `locationd`,
`securityd`, `trustd`, `runningboardd`, `lsd`, `installd`,
`containermanagerd`, `tccd`, `mediaserverd`, `dasd`, and the other labels in
[`NeverDisable.swift`](../Sources/FastIOSCore/NeverDisable.swift). Turning
them off stops the simulator from starting, hangs app launch, or breaks
basic system UI. fast-ios leaves them out of every light set, and `off`
turns them back on if another tool turned them off. `assistantd` and
`gamed` are core processes; the Siri and game-controller services in the
[service table](commands.md#keep-a-service-on) are other labels, which are turned off.

## Limits

- Do not run fast-ios and `simslim watch` on the same set of simulators.
  Both write the same launchd overrides, and simslim's watch makes every
  running simulator light with its own list, so `fast-ios off` will not
  stay full. Use `--set <path>` to give fast-ios a set of its own.
- The overrides file is an undocumented CoreSimulator detail. fast-ios
  checks the result after each start and falls back to `launchctl` when a
  runtime ignores it.
- Runtimes older than iOS 18.5 keep overrides in memory only; they come back
  full after a restart.
- `simctl clone` does not copy overrides (they are keyed by UDID). `lease`
  writes them again on every clone it makes from a template; the background
  helper catches parallel-testing clones in `XCTestDevices` when it sees
  them before their first start.
- The light set only sees what the app declares and links. A service reached
  some other way (a deep link into Settings, a test that opens Maps) needs
  `--keep`, or self-repair when the failure shows in the log.
