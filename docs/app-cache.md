# App cache: reuse a built simulator app

Part of fast-ios 0.4.0. Feasibility pass and evidence, 17 Nov 2026, on an
Apple M5 Mac, Xcode 27.2 (27B52), macOS 27.0. Back to the
[README](../README.md).

**Main point.** When many agents work in separate git worktrees of one app,
each one compiles the same native app. fast-ios now keys each built
simulator `.app` by a fingerprint of what it is built from, stores it once,
and installs the stored app when the fingerprint matches. On an Expo
project the fingerprint covers native inputs only, so an agent that changed
only JavaScript skips the compile. On a pure Xcode project only identical
sources match.

| Sample project | Compile (a miss) | App cache hit | Saved per hit |
|---|---|---|---|
| Expo SDK 58 with `expo-dev-client`, keyed by native inputs | 254 s | 0.90 s | 253.1 s |
| SwiftUI app, 62 Swift files, keyed by every file | 70.9 s | 0.30 s | 70.6 s |

From `fast-ios bench --scenario build --repeat 5` (output in
[`docs/bench/2026-11-17-app-cache-expo.json`](bench/2026-11-17-app-cache-expo.json)
and [`…-xcode.json`](bench/2026-11-17-app-cache-xcode.json)). The compile
is one clean `xcodebuild` into a fresh `-derivedDataPath`; a hit is the
fingerprint plus the cache lookup, median of 5. The Mac was busy with other
work (load average about 30), so the compiles are slower than on an idle
Mac: earlier the same clean compiles took 187.8 s (Expo) and 35.2 s
(SwiftUI), timed with `/usr/bin/time`. Install and launch cost the same
either way and are not in the table.

## 1. What identifies "the same native app"

### Expo and React Native (with `@expo/fingerprint` installed)

A Debug simulator build of an Expo app does not contain its JavaScript:
the React Native build script skips bundling for Debug simulator builds
and the app loads JavaScript from Metro. Checked on the sample: the built
`sampleexpo.app` (194 MB) has no `main.jsbundle`.

So the fingerprint should cover the native inputs only. `@expo/fingerprint`
(0.21.10 in the sample, a dependency of `expo`) already defines them: the
`ios/` folder when it is not ignored, every autolinked native module, config
plugins, the app config, `package.json` scripts that run native steps, and
patches. fast-ios calls it when `node_modules/@expo/fingerprint` exists,
with `--platform ios --preset strict`. The default preset ("balanced")
skips the app version and build number, which end up in Info.plist; a
wrong Info.plist is a wrong app, so fast-ios uses "strict".

Tested on the sample (`node node_modules/@expo/fingerprint/bin/cli.js
fingerprint:generate --platform ios --preset strict | jq -r .hash`, before
and after each change, each change reverted after):

| Change | Expo fingerprint |
|---|---|
| Edit `App.tsx` (JavaScript) | unchanged |
| Add `.env` with `EXPO_PUBLIC_API=x` | unchanged |
| `expo.version` 1.0.0 to 1.0.1 | changed |
| `expo.ios.bundleIdentifier` changed | changed |

fast-ios adds to it: the Xcode version and build, the configuration, the
Mac's architecture, an optional `--variant`, and `.env` files at the root
and in `ios/` (the table shows `@expo/fingerprint` does not see `.env`;
`app.config.js` can read it, so fast-ios counts it and misses instead).

fast-ios calls `@expo/fingerprint` rather than computing its own Expo
rules: Expo CLI's own `buildCacheProvider` keys builds by the same
fingerprint hash (read in the sample's
`node_modules/@expo/cli/build/src/utils/build-cache-providers/index.js`),
it knows autolinking, and it changes with the SDK. The cost is
node on PATH and about 1.7 s per call (measured below).

### Pure Xcode and SwiftPM apps

Every Swift or resource change changes the binary, so the fingerprint is
every file in the git repository: tracked files by their git blob ID (read
from the index, no hashing), changed and untracked files hashed the same
way git does, so a clean and a dirty copy of the same content agree.
Ignored files do not count, except `.env` files. Outside git, fast-ios walks
the folder and skips `build`, `DerivedData`, `Pods`, `node_modules`,
`.build` and `xcuserdata`.

### How often each case hits (a judgement, not measured)

- **Expo, many agents on JavaScript tasks:** most runs hit. A miss needs a
  native change: a new native module, an SDK upgrade, an app config change,
  a pod update.
- **Expo Release builds:** keyed by every file, because the JavaScript is
  inside. Rarely hits; fast-ios does not try harder.
- **Xcode or SwiftPM app:** hits only for identical sources, which mostly
  means several worktrees made from the same commit before anyone edits
  native code (for example, agents that each start by running the app
  before changing it). After an agent edits a Swift file, its own runs miss.
  This is the honest ceiling: incremental compilation in the worktree's own
  DerivedData is the better tool for that case.

## 2. What is never reused

A wrong reuse is worse than a slow build, so when in doubt fast-ios misses.

| Case | How it is kept out | Test |
|---|---|---|
| Another bundle ID, team or entitlements | They live in the project files and app config, which are in both fingerprint kinds | `dirtyFiles`, Expo table above |
| Another configuration | The configuration is in the fingerprint; `apps add` refuses an app whose folder says another configuration (`Release-iphonesimulator` stored as Debug) | `settingsChangeIt`, `neverStore` |
| A build with JavaScript inside, after a JavaScript change | Release is keyed by every file; a Debug app with `main.jsbundle` is refused for the Expo kind | `expoReleaseUsesFiles`, `neverStore` |
| Different embedded environment values | `.env` files count in both kinds; `--variant` for values the files do not show | `untrackedIgnoredEnv` |
| A device build, an app without a bundle ID, an app not built for this Mac's architecture | Checked from Info.plist and `lipo -archs` before storing, and the architecture again before reuse | `neverStore`, `reuseRules` |
| Dependencies that float | A Podfile without Podfile.lock, or Swift packages from a URL without Package.resolved: not cached at all | `unpinned` |
| A submodule with uncommitted changes | Not cached | (code path only) |
| Another Xcode version | In the fingerprint | `settingsChangeIt` checks it is present |

Known gaps, by design or not yet closed:

- **Settings passed only on the build command line** (`-scheme`,
  `DEVELOPMENT_TEAM=...`, `APP_VARIANT=staging npx expo run:ios`) are not
  in the files. Pass `--variant <text>` for them, or set environment
  variables before running fast-ios, not inside `--build`: `app.config.js`
  is evaluated in fast-ios's environment.
- **Absolute paths in debug info.** The sample's
  `sampleexpo.debug.dylib` contains the builder's absolute paths (checked
  with `rg -a`). Running the app does not use them; a debugger attached to a
  reused app maps sources to the worktree that built it.
- **Machine-wide inputs outside Xcode**, such as a CocoaPods or node
  version that changes generated code without changing a lockfile, are not
  in the fingerprint.

## 3. Where the time goes

Per run, from the bench JSON (seconds, 5 runs after one warm-up):

| | Expo sample | SwiftUI sample |
|---|---|---|
| Fingerprint alone | 2.05, 1.37, 1.36, 0.94, 0.92 (median 1.36) | 0.64, 0.49, 0.46, 0.50, 0.33 (median 0.49) |
| Hit: fingerprint + lookup | 2.88, 1.54, 0.84, 0.68, 0.90 (median 0.90) | 0.52, 0.34, 0.29, 0.26, 0.30 (median 0.30) |
| Inputs in the fingerprint | 31 | 71 |
| Stored app size | 194 MB (APFS clone: no extra disk until changed) | 10 MB |

The hit median is below the fingerprint median because the runs are
noisy on a loaded Mac; both are one fingerprint. Where the time goes:

- **Expo:** almost all of it is `node` starting and `@expo/fingerprint`
  hashing native module folders. Run by hand, it took 1.75 s wall time.
- **Files kind:** five short `git` and `xcode-select` processes (about
  0.1 s each to start from Swift, measured with a small Swift program) and
  hashing only the changed files. Unchanged files cost nothing: their IDs
  come from the git index.
- **The first run of a newly compiled fast-ios** took 4 s for the same
  work, with almost no CPU; repeat runs took 0.4 s. A guess: macOS checks a
  new binary on its first launch. The bench does one warm-up run for this
  reason.

The fingerprint is computed only when something is stored for the project
or `--build` is given, so projects that do not use the cache pay nothing.

## 4. What was built

- `FastIOSCore/AppFingerprint.swift`: the two fingerprint kinds, the
  pinned-dependency check, and the input diff.
- `FastIOSCore/AppCache.swift`: the store in
  `~/Library/Caches/fast-ios/apps/<fingerprint>/` (`FASTIOS_CACHE_DIR`
  moves it), one `manifest.json` per app (inputs, bundle ID, configuration,
  architectures, Xcode version, built at, size, build time), APFS clones
  for copies, a 10 GB cap (`FASTIOS_APP_CACHE_GB`) with least recently used
  eviction.
- `FastIOSCore/AppCache+Build.swift`: single flight. The builder holds a
  `flock` on `.locks/<fingerprint>.lock` and writes its process ID and
  command into it; others poll for the stored app and say who they wait
  for. The kernel drops the lock when the builder dies, so the next waiter
  builds. After `--build-timeout` (20 minutes) a waiter stops with an error
  that names the building process.
- `run` and `shot` with a project folder: they compute the fingerprint only
  when something is stored for the project or `--build` is given, so the
  cache costs nothing until it is used.
- `fast-ios apps`, `apps why`, `apps add`, `apps clear`, all with `--json`;
  the MCP tool `apps`; `build`, `builtApp`, `configuration`, `variant` and
  `buildTimeout` arguments on the `run` and `shot` tools.
- `fast-ios bench --scenario build`.

## 5. End to end, on this Mac

All on a simulator I created in a private device set (`--set`), with
`FASTIOS_CACHE_DIR`, `FASTIOS_STATE_DIR` and `FASTIOS_TEMPLATE=off`, then
deleted. Release binary of this branch.

SwiftUI sample, three git worktrees at the same commit (a, b, c):

1. b and c ran `fast-ios run --build "xcodebuild … -derivedDataPath
   build/dd build -quiet" --json` at the same time, 1 s apart. b:
   `"status": "built"`, "Built and stored the app in 29.5 s". c:
   `"status": "waited"`, "Another agent built this app while this one
   waited 28.7 s; reusing it." c never compiled: it has no `build/` folder.
   Both apps launched.
2. c ran `fast-ios run` with no `--build`: "Reused the app built 44 s ago:
   source files unchanged. Skipped a compile that took 29.5 s." App opened
   in 1.9 s.
3. One line added to `Sources/Screen1.swift` in c. `fast-ios apps why .`:
   "Miss: e311082dd6a0 differs from the stored SampleXcode.app
   (0a54fa56d8d0, built 46 s ago) in 1 input: Sources/Screen1.swift."
   `run` then said no stored app matches, named `apps add` and `--build`,
   and fell back to looking for a local build (none: it stopped with the
   existing "No simulator build found" error).
4. `fast-ios shot --app . --no-tree --json` in c: `appCache.status` "hit",
   the app cache step took 167 ms.

Expo sample, two git worktrees (a, b), each with its own `bun install`:

1. `fast-ios apps add <a's Debug .app> --project <a> --build-seconds 187.8`.
2. In b, `App.tsx` edited (JavaScript only), then `fast-ios run`:
   "Reused the app built 38 min ago: native code unchanged. Skipped a
   compile that took 187.8 s." The dev client opened.
3. Metro started in b (`expo start --dev-client --port 8099`) and the
   reused app launched with `--initialUrl http://127.0.0.1:8099`. Metro
   logged `iOS Bundled 1873ms index.ts (712 modules)`, and the screenshot
   shows b's edited text. So the app built in a ran b's JavaScript.
4. `bunx expo install expo-haptics` in b. `fast-ios apps why .`: "Miss:
   d7d91250d0d9 differs from the stored sampleexpo.app … in 3 inputs:
   expoAutolinkingConfig:ios, the whole Expo fingerprint,
   node_modules/expo-haptics/ios."

Tests: `swift test` runs 18 app cache tests (fingerprint rules, the
never-reuse cases, eviction, single flight with five concurrent callers, a
builder killed with SIGKILL, a waiter timeout, a failed builder); the full
suite is 128 tests.

## What this does not prove

- The hit rates in section 1 are judgement. No measurement of real agent
  sessions was made.
- The samples are small apps made for this check (a 62-file SwiftUI app made with xcodegen, and
  a blank Expo SDK 58 app with `expo-dev-client`), not the owner's apps.
  The 107 s compile quoted in the request was not reproduced here.
- Only Expo projects with `@expo/fingerprint` get native-only keys. A bare
  React Native project without it is keyed by every file.
- `simfleet`'s `buildCacheProvider` was not run or compared; Expo's own
  `buildCacheProvider` uses the same `@expo/fingerprint`, which is the basis
  here.
