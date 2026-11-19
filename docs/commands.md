# Commands

Back to the [README](../README.md). `fast-ios help` lists every command; `fast-ios <command> --help` explains one.

## Everyday

- Simulators that are not running become light at once. A running one
  becomes light the next time you start it.
- New simulators are light from their first start.
- A small background helper does this. It also turns services back on when
  an app needs them ([self-repair](how-it-works.md#self-repair-turn-on-what-the-app-calls)).

To see where you are, run `fast-ios` with nothing after it:

```
fast-ios 0.3.0
Automatic: on. Every simulator stays light.
Simulators: 2, 2 light, 1 running.
  My iPhone (iOS 27.0) is running light, using 773 MB
Saving about 2.0 GB compared with full simulators.

Next: nothing to do. `fast-ios help` lists everything else.
```

(Real output, 15 Nov 2026, iPhone 18 Pro on iOS 27.0, one minute after it
started. It names only running simulators; `fast-ios status` lists all of
them. "Saving" compares with a full simulator measured at 2,845 MB.)

To undo everything:

```bash
fast-ios off
```

Every simulator goes back to full, and nothing of fast-ios runs in the
background. A running simulator is not restarted; it is fully back to normal
after its next start. The menu-bar app's "Keep simulators light" switch is
the same switch as `fast-ios on` and `fast-ios off`.

If another tool already turns off simulator services (simslim's watch
helper), `fast-ios on` stops, changes nothing, and tells you how to turn
that tool off first: two tools doing this undo each other's work.

| Everyday | |
|---|---|
| `fast-ios` | Is it on, what is running, what you save, and the one next step |
| `fast-ios on` / `fast-ios off` | Keep every simulator light / undo it all |
| `fast-ios status` | Every simulator: running or not, light or full, memory |
| `fast-ios run` | Open your app on a light simulator (from the project folder) |
| `fast-ios shot --app <app>` | Open the app and save a screenshot |
| `fast-ios doctor` | Check your Mac; a fix for each problem |

`fast-ios help` lists the advanced commands; `fast-ios <command> --help`
explains one; `--verbose` shows the details the everyday output leaves out.
Colour follows the usual rules (`NO_COLOR`, `--no-color`, off in a pipe);
details and stills in [`docs/design/cli/`](design/cli/).

## Run your app

Build your app once for the simulator. Then, from the project folder:

```bash
fast-ios run                    # find the build, get a light simulator, install, launch
fast-ios run --url myapp://cart # same, then open a deep link
```

At a terminal, `run` opens the Simulator window so you see your app. With
`--json` or `--headless` it opens no window, for scripts and agents.

With no `--app`, `run` picks the newest simulator build of the project in the
current folder (Xcode DerivedData whose workspace is in this folder,
`ios/build` for Expo, or `build/`) and says which one. It prints the
simulator's ID (UDID) on stdout, so `UDID=$(fast-ios run)` works. The
simulator stays yours until `fast-ios release <udid>`, until `--ttl` passes
(30 minutes), or until your shell exits. After that it keeps running, so the
next `run` only installs and launches.

When macOS memory pressure is above normal, or too little memory is free,
`run` starts nothing and stops within seconds with exit code 2. It says
why, lists the running simulators (name, UDID, memory, who holds it, which
apps run on it) and the largest apps, and gives the choices:

- reuse a running simulator: `fast-ios run --simulator <udid>`
- start a new one anyway: `--max-pressure warning` (the Mac may slow down)
- shut down a simulator you do not need: `xcrun simctl shutdown <udid>`
- wait for memory: `--wait-for-memory 5m` prints a line about every 30 s
  and stops with exit code 2 if memory is still short after 5 minutes

`--timeout` is the old name of `--wait-for-memory` and still works. With
`--json`, the error code is `memory_pressure`. A request behind another
agent's simulator that is still starting waits up to 5 minutes for it,
with the same progress lines; `lease` behaves the same way.

### Skip the compile: the app cache

Several agents in separate git worktrees of one app each compile the same
native app. fast-ios can store a built simulator app once and install it
in every worktree whose native code is unchanged:

```bash
fast-ios run --build "xcodebuild -workspace ios/MyApp.xcworkspace -scheme MyApp \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build build"
# Another worktree, JavaScript changed, native code not:
fast-ios run   # Reused the app built 2 hours ago: native code unchanged. Skipped a compile that took 187.8 s.
```

On a miss, `--build` runs your command once in the project folder, stores
the app, and installs it. Agents that miss on the same app at the same time
wait for that one build instead of compiling it again. Without `--build`,
store a build you already have with `fast-ios apps add <app> --project .`.

What counts as "the same app" is a fingerprint:

- **Expo** (with `@expo/fingerprint` installed, Debug builds): native inputs
  only, from `@expo/fingerprint`. A JavaScript change still reuses the app:
  a Debug build loads JavaScript from Metro.
- **Any other project:** every file in the git repository, so only
  identical sources reuse an app, such as another worktree at the same
  commit.
- Both add the Xcode version, the configuration, the Mac's architecture,
  `--variant` and `.env` files. A project whose dependency versions can
  change (a Podfile without Podfile.lock, Swift packages without
  Package.resolved) is never cached.

| Sample project (17 Nov 2026, Apple M5, busy Mac) | Compile | Reuse |
|---|---|---|
| Expo SDK 58 with `expo-dev-client` | 254 s | 0.90 s |
| SwiftUI app, 62 Swift files | 70.9 s | 0.30 s |

From `fast-ios bench --scenario build --repeat 5` on small sample apps made
for the check, not real apps. Install and launch are not included: they
cost the same either way.

```bash
fast-ios apps            # stored apps, newest use first
fast-ios apps why .      # does this project match a stored app? If not, which inputs differ
fast-ios apps clear      # remove them all
```

Stored in `~/Library/Caches/fast-ios/apps`, at most 10 GB
(`FASTIOS_APP_CACHE_GB`); the least recently used go first. Rules, what is
never reused, and the evidence: [docs/app-cache.md](app-cache.md).

```bash
fast-ios doctor                                 # Xcode, runtimes, memory, disk, a conflicting simslim helper; a fix per problem
fast-ios <command> --help                       # options and examples for one command
fast-ios completions zsh > ~/.zfunc/_fast-ios   # also fish, bash
```

Step by step, on a simulator you created (advanced):

```bash
fast-ios profile path/to/MyApp.app              # which services the app needs, and why; changes nothing
fast-ios slim booted --app path/to/MyApp.app    # make this simulator light for the app (restarts it)
fast-ios measure booted                         # process count and memory
fast-ios off booted                             # back to full
```

`slim` is the advanced command that makes one simulator light for one app.
`--app` also takes a DerivedData folder, `Build/Products`, or your project
folder; in a folder it uses the newest `…-iphonesimulator/*.app`. `slim`
remembers the light set, so a later `slim <sim>` reuses it.

| Command | What it does |
|---|---|
| `fast-ios run` | Get a light simulator, install, launch; prints the UDID |
| `fast-ios apps` | The app cache: built apps reused while native code is unchanged |
| `fast-ios pool --size N` | Keep N light simulators running and free for the next `run` or `lease` |
| `fast-ios doctor` | Checks the Mac; a fix line for each problem |
| `fast-ios bench` | Full vs fast-ios vs simslim, measured on your Mac |
| `fast-ios status` | Every simulator: light or full, running or not, memory (`--verbose`: light set, UDID) |
| `fast-ios watch` | Makes each new simulator light before its first start, in this terminal (`on` does this in the background) |
| `fast-ios catalog` | Every service fast-ios may turn off, by category, and what breaks |
| `fast-ios lease` / `release` / `leases` | A shared pool of light simulators for agents |
| `fast-ios shot` | Install, launch, screenshot and accessibility tree in one call |
| `fast-ios heal` / `repairs` | Turn a service on when the app calls it, without `fast-ios on` |
| `fast-ios mcp` | The same commands as an MCP server |

Every command takes `--set <path>` for a separate set of simulators (a
CoreSimulator device set; the folder is created if it does not exist),
`--json` for machine-readable output, and `--help` for its options and
examples. Exit codes, for every command: `0` ok, `1` failed (the error says
the next step), `2` no simulator started: memory is short or the queue ran out (the error says what to do), `64` bad
arguments.

## Keep a service on

Only services your app does not use are off, but your test flows may still
touch them: a deep link into Settings, a test that opens Maps, a widget you
want to see update.

```bash
fast-ios catalog                                 # every category and service, and what breaks
fast-ios profile path/to/MyApp.app               # which services are off for this app, and why
fast-ios run --keep widgets                      # keep a whole category on
fast-ios slim booted --keep com.apple.apsd       # keep one service on
fast-ios off booted                              # make this simulator full again
```

`--keep` takes a category ID from the table (`widgets`), its full name
(`"Widgets & Wallpaper"`), or one service's label from `fast-ios catalog`
(`com.apple.chronod`). It repeats.

| Category | ID | Approx. memory | Off means |
|---|---|---|---|
| Widgets & Wallpaper | `widgets` | ~675 MB | Home and Lock Screen widgets, wallpaper posters, and Live Activities stop updating. |
| Siri & Intelligence | `siri` | ~265 MB | Siri, speech features, and Apple Intelligence services are unavailable. |
| Spotlight & Search | `search` | ~50 MB | Spotlight and Settings search return no results, and Recents in Files and the document picker fails to load. |
| iCloud & Apple Account | `icloud` | ~100 MB | iCloud sync, Apple Account, Keychain, and backup workflows will not work. |
| App Store, Push & Media | `store` | ~80 MB | Remote push notifications and StoreKit or App Store testing will not work. |
| Mail, Calendar & Contacts | `pim` | ~80 MB | Contacts, Calendar, Reminders, and Mail-backed pickers or sync may fail. |
| Safari Sync & Web Services | `web` | ~50 MB | Universal links and Safari sync or background web services will not work. |
| Family & Screen Time | `family` | ~65 MB | Family Sharing, Screen Time, and usage tracking stop working. |
| Health, Home & Fitness | `health` | ~135 MB | HealthKit, HomeKit, and Fitness integrations will not work. |
| Photos & Media Analysis | `photos` | ~60 MB | Photo picker, Photos-library workflows, and media analysis may fail. |
| News, Weather, Maps & Games | `apps` | ~90 MB | News, Weather, Maps background data, and game-controller services are unavailable. |
| Messaging & FaceTime | `messaging` | ~60 MB | iMessage, FaceTime, and related identity services will not work. |
| Sharing & Device Connectivity | `connectivity` | ~65 MB | AirDrop, Continuity, CarPlay, Watch, and Find My connectivity will not work. |
| Ads, Diagnostics & Telemetry | `telemetry` | ~105 MB | DeviceCheck plus analytics, diagnostics, and feedback services are unavailable. |
| Device Management | `mdm` | ~10 MB | Declarative device management, and MDM or configuration-profile workflows that use it, will not work. |
| Other Background Services | `other` | ~225 MB | Wallet, App Clips, accessibility asset downloads, merchant, business, and miscellaneous background services are unavailable. |

Memory figures are simslim's medians on iOS 26.5 (only that category on,
everything else off); they are not additive.

## Grant permissions before launch

`run --grant <permission>` and `shot --grant <permission>` (repeatable)
answer permission prompts before the app starts, with `xcrun simctl privacy
grant`, so the first screen is the app and not a system alert.

What works, measured with [`scripts/privacy-probe`](../scripts/privacy-probe)
(a tiny app that reads each authorization status without asking) on Xcode
27.2:

| Permission | iOS 27.0 | iOS 26.5 |
|---|---|---|
| calendar, contacts, contacts-limited, reminders, microphone, motion, media-library, photos-add | granted | granted |
| photos (full library) | granted | still asks |
| location, location-always | granted as "when in use" | granted as "when in use" |
| siri | written; not verified (reading it needs an entitlement) | same |
| notifications, camera, speech, tracking | still asks: `simctl privacy` has no such service | same |
| bluetooth | no prompt on the simulator: already allowed | same |

`--grant all` grants each service on its own. `simctl privacy grant all`
itself writes a single "all" entry that apps ignored in the probe: only
location changed. fast-ios refuses the names in the "still asks" row with
the reason, instead of pretending to grant them.
