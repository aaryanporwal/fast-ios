<img src=".github/tiger.png" width="120" alt="The fast-ios tiger">

# fast-ios

**iOS simulators that need a third of the memory.** An iPhone simulator
starts close to 280 background processes and uses almost 3 GB of memory,
mostly for things your app never touches: widgets, Siri, iCloud, Maps.
fast-ios turns those off before the simulator starts. It is for iOS
developers on a Mac, and for coding agents that run several simulators at
once.

```bash
fast-ios on     # every simulator light from now on
fast-ios        # is it on, what is running, what you save, what to do next
fast-ios off    # every simulator back to full
```

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
start. Nothing is deleted, and no app data is touched. Details:
[Self-repair](#self-repair-turn-on-what-the-app-calls).

## Measured

| One iPhone 18 Pro simulator, iOS 27.0 | Background processes | Memory used |
|---|---|---|
| Full | 277 | 2,845 MB |
| Light, for one real app | 93 | 829 MB |

Apple M5, Xcode 27.2, 3 minutes after the simulator started. The app was a
real Expo app (push, photos, speech, universal links, StoreKit); fast-ios
read its light set from the built app with no hand edits: 18 services kept,
155 off. Made with `fast-ios slim booted --app <app>`, then measured with
`fast-ios measure booted`, which counts the simulator's processes and adds
up their memory. Your number depends on what your app uses.

| Time until the app is running | Median |
|---|---|
| Full simulator: create, start, install, launch | 36.2 s |
| `fast-ios run`, first time | 12.1 s |
| `fast-ios run`, next time | 2.3 s |

From one run of `fast-ios bench --scenario app --repeat 3` with a real Expo
app, measured until the app's process starts. `fast-ios run` keeps a light
simulator running after you are done, so the next run only installs and
launches. Every row, the comparison with simslim and what to keep in mind:
[Full benchmark](#full-benchmark).

<img src="docs/demo/fast-ios-demo.gif" width="880" alt="Terminal: fast-ios shows an iPhone 18 Pro simulator running full at 3,017 MB; fast-ios on; the simulator restarts; fast-ios run starts MyApp in 24.6 s, then again in 1.1 s; fast-ios shot saves a screenshot; fast-ios shows the simulator running light at 661 MB.">

A real recording, made with [vhs](https://github.com/charmbracelet/vhs)
from [`docs/demo/demo.tape`](docs/demo/demo.tape) on the same Mac, with a
sample app built from [`docs/demo/MyApp`](docs/demo/MyApp). It is a
different run from the tables, so its numbers differ: the full simulator
used 3,017 MB here. The "about 4.2 GB" on the last screen counts two
running light simulators: the one shown and the one `fast-ios run` started.
Two idle waits are cut: 3 s while the stopped simulator is made light, and
150 s while memory settles. Reproduce it with `docs/demo/prepare.sh && vhs
docs/demo/demo.tape && docs/demo/teardown.sh`.

## Install

You need macOS 15 or newer, an iOS 18.5 or newer simulator runtime, and, to
compile from source, Swift 6.3 or newer (Xcode 26.6 or newer). CI compiles
and tests every pull request on Xcode 26.6 (Swift 6.3), and again on any
newer Xcode the GitHub runner image gains.

**One line in Terminal (recommended).** Paste this; it installs the menu-bar
app and the `fast-ios` command with no security warning:

```bash
curl -fsSL https://raw.githubusercontent.com/aaryanporwal/fast-ios/main/packaging/install.sh | bash
```

What [`packaging/install.sh`](packaging/install.sh) does:

1. Downloads the latest release zip of `fast-ios.app` from GitHub with `curl`.
   macOS does not mark files fetched with `curl` as downloaded, so it shows no
   "Not Opened" warning. The script never removes that mark from anything.
2. Puts `fast-ios.app` in `/Applications` (or `~/Applications` if that needs a
   password), replacing an older copy by rename.
3. Links the `fast-ios` command into the first writable folder of
   `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`, unless another
   install of the command is already there.
4. Restarts fast-ios's background helper if it runs from that link, so it
   picks up the new version.
5. Opens the app, which walks you through setup.

It asks for no password. `FASTIOS_FROM_SOURCE=1` builds the app from source
with Xcode instead of downloading it.

**Homebrew, for developers.** Builds fast-ios from source on your Mac, also with
no warning, and installs both the command and the menu-bar app:

```bash
brew install aaryanporwal/fast-ios/fast-ios
```

The app is at `$(brew --prefix)/opt/fast-ios/fast-ios.app`. `brew upgrade
fast-ios` updates both.

**Or download the app.** Open the DMG from the
[latest release](https://github.com/aaryanporwal/fast-ios/releases/latest) and
drag fast-ios to Applications. fast-ios is free and not notarized with Apple,
so macOS blocks the first open; the source is all here to read. The first
time, macOS shows **“fast-ios” Not Opened**, with the buttons Move to Trash and
Done:

1. Click **Done**. Never Move to Trash: that deletes the app.
2. Open System Settings, then Privacy & Security.
3. Scroll down to Security. Next to "“fast-ios” was blocked to protect your
   Mac.", click **Open Anyway**, then confirm.

<!-- SCREENSHOT SLOT: site/public/open-anyway.webp (that Security row, macOS 27.0.1). -->

If that is more than you want, use the one-line install above instead.

To remove fast-ios, see [Uninstall](#uninstall).

## Quick start

```bash
fast-ios on
```

That is all. Every simulator on your Mac is now light. Keep using Xcode,
Expo or `simctl` exactly as before.

- Simulators that are not running become light at once. A running one
  becomes light the next time you start it.
- New simulators are light from their first start.
- A small background helper does this. It also turns services back on when
  an app needs them (see above).

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
details and stills in [`docs/design/cli/`](docs/design/cli/).

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

When memory is short, `run` says why it waits, waits briefly, and then
tells you what to do next: quit a simulator you do not need, or use one you
already have with `--simulator <udid>`.

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
never reused, and the evidence: [docs/app-cache.md](docs/app-cache.md).

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
the next step), `2` refused for memory or queue (try again later), `64` bad
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

## For agents

Five agents starting five full simulators is how a Mac runs out of memory.
fast-ios gives each agent a light simulator from one shared pool, waits when
memory is short, and takes the simulator back when the agent is done. Every
command prints one JSON object with `--json`, so an agent needs nothing but
its shell.

Which command to use:

- **`run`** when the agent runs your app. It finds the build, gets a light
  simulator, installs and launches the app, and prints the UDID.
- **`lease`** when the agent installs and tests with its own tools, such as
  `xcodebuild test` or `simctl`. It only hands over a light, running
  simulator.
- **`release`** after either, to give the simulator back. It also goes back
  by itself when the agent exits or `--ttl` passes.

```bash
UDID=$(fast-ios run --app path/to/MyApp.app --json | jq -r .udid)
fast-ios shot --app path/to/MyApp.app --udid "$UDID" --url myapp://settings --json
fast-ios release "$UDID"
```

Paste this into your project's `AGENTS.md` or `CLAUDE.md`:

```markdown
## iOS simulator
Get a simulator from fast-ios. Do not create or start your own.

UDID=$(fast-ios run --app <path to .app or project folder> --json | jq -r .udid)
fast-ios shot --app <path to .app> --udid "$UDID" --json   # see the screen
fast-ios release "$UDID"                                    # when done

To test with your own tools instead (xcodebuild test, simctl), get the
simulator with `fast-ios lease --app <app> --json | jq -r .udid`.
Never run `fast-ios on`, `fast-ios off` or `fast-ios slim` yourself: they
change simulators other people use.
If a system feature fails (photos, contacts, widgets), run
`fast-ios profile <app>` to see which services are off. Ask before
keeping one with `--keep <category>` (categories: `fast-ios catalog`).
```

### Set up the MCP server and the skill

The MCP server offers the same commands as tools: `run`, `doctor`, `lease`,
`release`, `leases`, `heal`, `repairs`, `status`, `profile`, `slim`, `off`,
`measure`, `catalog`, `shot` and `pool`, each with a JSON Schema for input
and output (`structuredContent`). It speaks MCP over stdio (JSON-RPC 2.0,
one message per line). The skill,
[`skills/fast-ios/SKILL.md`](skills/fast-ios/SKILL.md), tells an agent when
to use fast-ios, how to get a simulator, what breaks, and never to touch a
simulator it did not create. Install fast-ios first. You do all of these
steps.

1. Claude Code, MCP server for every project. Run in any folder:

   ```bash
   claude mcp add --scope user fast-ios -- fast-ios mcp
   ```

   This lets Claude Code start `fast-ios mcp` when a session begins.
2. Check it. Run in any folder:

   ```bash
   claude mcp get fast-ios
   ```

   It prints `Command: fast-ios` and `Args: mcp`. If it prints that no
   server was found, step 1 did not run.
3. Claude Code, skill. Run in any folder:

   ```bash
   mkdir -p ~/.claude/skills/fast-ios && curl -fsSL https://raw.githubusercontent.com/aaryanporwal/fast-ios/main/skills/fast-ios/SKILL.md -o ~/.claude/skills/fast-ios/SKILL.md
   ```

   This saves one file, `~/.claude/skills/fast-ios/SKILL.md`. Without it,
   the agent has the tools but not the rules for using them safely.
4. Codex, MCP server. Add these lines to `~/.codex/config.toml`:

   ```toml
   [mcp_servers.fast-ios]
   command = "fast-ios"
   args = ["mcp"]
   ```

5. Start a new agent session, so the agent loads the server and the skill.

For one project only, put this in `.mcp.json` in the project folder
(`claude mcp add --scope project fast-ios -- fast-ios mcp` writes it):

```json
{
  "mcpServers": {
    "fast-ios": { "command": "fast-ios", "args": ["mcp"] }
  }
}
```

Add `"--set", "<path>"` to `args`, or pass `deviceSet` in a tool call, to use
a separate set of simulators. Test the server with the scripted client in
[`tests/mcp-client.ts`](tests/mcp-client.ts) (needs `bun` and a simulator you
created in a separate set).

**JSON.** stdout is one JSON object (`watch` and `heal`: one per line) with
`schemaVersion` (now 1). Errors are JSON on stdout with an `error.code` and
exit code 1 (64 for bad arguments). A refused `lease` exits 2 with
`"status": "refused"`. Some field names come from before the words light
and full: `"slim": true` means light. Real samples for every command:
[`docs/json-output.md`](docs/json-output.md).

## Leases: one simulator pool for many agents

```bash
UDID=$(fast-ios lease --app path/to/MyApp.app --ttl 30m --json | jq -r .udid)
xcrun simctl install "$UDID" path/to/MyApp.app
fast-ios release "$UDID"
fast-ios leases --json        # who holds what, the pool, the queue, memory
```

- **Order:** a free running pool simulator first (no new memory, no start),
  a stopped one second, a new one (`fast-ios-lease-…`) last.
- **Ends by itself:** at `release`, when `--ttl` passes, or when the owner
  exits. The owner is `--pid`, or else the caller: the first parent process
  that is not a shell, so a lease taken from an agent's `zsh -c` tool call
  lives as long as the agent. Any later `lease`, `release` or `leases` call
  frees dead leases.
- **Memory:** a new simulator starts only while the kernel's memory pressure
  (`kern.memorystatus_vm_pressure_level`) is normal and available memory
  (free + inactive + speculative + purgeable pages) minus the starts in
  progress leaves `--need-mb` (1500) plus `--reserve-mb` (2048). Otherwise
  the request waits in a first-come queue, an idle pool simulator of another
  kind is shut down to make room, and after `--timeout` `lease` exits 2 with
  JSON that says why (`reason`: `memory` or `queue`, `detail`,
  `waitedSeconds`, `memory`, `policy`). `--max-pressure warning` relaxes the
  pressure rule.
- **Warm pool:** a released simulator keeps running for the next lease; idle
  pool simulators beyond `FASTIOS_MAX_IDLE` (1) are shut down.
- **Safe for parallel callers:** state is in
  `~/Library/Application Support/fast-ios/leases.json`, changed only under
  `flock(2)` on `leases.lock`. The lock is never held across a start. No
  daemon.
- **Only its own simulators:** `lease` uses only simulators it created.
  `--allow-existing` adds stopped simulators that already exist; running
  ones are never taken, since a person may be using them.
- **Templates:** a new pool simulator is a `simctl clone` of a stopped light
  template that already finished its slow first start
  (`fast-ios-template-…`, one per set of simulators, runtime and device
  type). The clone gets its overrides written again, since `clone` does not
  copy them. The first new simulator without a template builds one in the
  background when memory allows; `fast-ios template` lists, builds or
  removes them, and `FASTIOS_TEMPLATE=off` turns them off. A template never
  gets an app and is never leased, so clones carry no app data.
- **Broken simulators are replaced:** a start that fails, hangs past the
  timeout, or ends with launchd not answering retires that simulator and
  the lease tries another (3 attempts, `FASTIOS_MAX_ATTEMPTS`). The timeout
  is 180 s (`FASTIOS_BOOT_TIMEOUT`), doubled under memory pressure
  "warning", tripled under "critical", and 1.5 times longer below 2 GB
  available, capped at 15 min. A retired simulator is deleted only if
  fast-ios created it; one that existed before is shut down and dropped
  from the pool. `run` does the same when a leased simulator refuses the
  launch. Each replacement is in the JSON (`replaced`: `udid`, `reason`,
  `detail`, `deleted`). In the parallel benchmark (3 agents, 2 rounds, one
  start made to hang each round), all 3 agents launched the app in both
  rounds.

## Shot: see the screen in one call

`fast-ios shot` is for an agent that changed some UI and needs to see it.

> **Read first:** the accessibility tree (the list of elements on screen)
> works only for simulators in your normal simulators, the ones Xcode
> shows. With `--set`, `shot` still returns the screenshot, says on its
> first line that the tree is not available, and sets
> `treeStatus: "unavailable"`. To keep your tests apart and still get the
> tree, use a simulator you or `fast-ios run` created in the normal set and
> pass its UDID with `--udid`. Why: `xcodebuild`, which reads the tree,
> cannot see a separate set; tried with and without
> `SIMULATOR_DEVICE_SET_PATH` and `CORESIMULATOR_DEVICE_SET_PATH` (15 Nov
> 2026, Xcode 27.2), it answers "Unable to find a device matching the
> provided destination specifier".

```bash
fast-ios shot --app <app|folder> [--udid <simulator>] [--url <deep link>] \
              [--wait <seconds|text>] [--timeout <seconds>] [--out <dir>] [--no-tree] --json
```

1. **Simulator.** `--udid` (started if needed); else a running light
   simulator; else a stopped iPhone, made light for this app and started. A
   running full simulator is never restarted.
2. **Install, launch, link.** Installs only when the built bundle differs
   from the installed one (file paths, sizes and modification dates; `simctl
   install` keeps them). Relaunches the app, then opens `--url`.
3. **Wait.** `--wait <seconds>` is the timeout (default 6 s) for the screen
   to settle: 3 screenshots 0.4 s apart that are the same, or that differ in
   under 1% of the screen (a spinner, a blinking caret), which is ignored.
   `screenStability` says which: `identical`, `small-animation` (with
   `changedPercent`) or `still-changing` (gave up at the timeout). On a
   "Searching for development servers" screen with a spinner, the screen
   settled as `small-animation` (0.17% changed) after 2.8 s; before this it
   waited the full timeout. `--wait <text>` waits up
   to 20 s (or `--timeout`) for an element whose label contains the text, or
   whose identifier is the text.
4. **Return.** A PNG, the accessibility tree as text (one element per line:
   type, label, identifier, value, flags, frame in points), the bundle id,
   the UDID and the time of each step. Progress lines go to stderr.

The same command is the MCP tool `shot`; its arguments are the options in
camelCase (`app`, `udid`, `url`, `wait`, `timeout`, `out`, `noTree`,
`deviceSet`) and it returns the same JSON.

Real output of `fast-ios shot --app … --udid … --url myapp:// --wait "Enter
URL manually" --json` (an Expo development build, iPhone 18 Pro booted by
the call, iOS 27.0, Xcode 27.2, M5). The app name, bundle id, URL scheme and
paths are replaced with neutral samples; nothing else is changed.
`screenStable` is false because the screen has a spinning activity indicator
(this was recorded before small animations were ignored; now the same screen
gives `screenStability: "small-animation"`):

```json
{
  "appPath": "~/Library/Developer/Xcode/DerivedData/MyApp-abc/Build/Products/Debug-iphonesimulator/MyApp.app",
  "bundleId": "com.example.myapp",
  "installed": true,
  "log": [
    "Booting fast-ios-shot-test2…",
    "Installing MyApp.app…"
  ],
  "openPromptAccepted": true,
  "schemaVersion": 1,
  "screenStable": false,
  "screenshot": "/tmp/shots/com.example.myapp-2026-11-15T191338+0530.png",
  "simulator": {
    "deviceType": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
    "name": "fast-ios-shot-test2",
    "runtime": "iOS 27.0",
    "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
    "state": "Booted",
    "udid": "414244D1-2A58-4AF3-8BEC-7DB59D5362A3"
  },
  "simulatorSource": "given",
  "timings": [
    { "ms": 18897, "step": "simulator" },
    { "ms": 5958, "step": "install" },
    { "ms": 350, "step": "launch" },
    { "ms": 161, "step": "openurl" },
    { "ms": 8, "step": "treeRunnerPrepare" },
    { "ms": 13276, "step": "tree" },
    { "ms": 5247, "step": "stableScreen" }
  ],
  "totalMs": 43901,
  "tree": "Application \"MyApp\" [0,0,402,874]\n  Window [0,0,402,874]\n    Image [16,72,32,32]\n    StaticText \"MyApp\" [60,70,115,20]\n    Button \"user-icon\" [350,70,36,36]\n    StaticText \"Development Build\" [60,92,106,14]\n    ScrollView [0,115,402,759]\n      StaticText \"DEVELOPMENT SERVERS\" [16,131,145,14]\n      Button \"INFO\" [358,131,28,14]\n      StaticText \"Searching for development servers...\" [32,173,279,20]\n      ActivityIndicator value=\"1\" [356,176,14,14]\n        ActivityIndicator value=\"1\" [356,176,14,14]\n      Button \"Enter URL manually\" [32,238,338,18]\n        Image \"Forward\" id=chevron.right [35,239,9,15]\n        StaticText \"Enter URL manually\" [53,238,126,17]\n      Other \"Vertical scroll bar, 1 page\" value=\"0%\" [369,115,30,676]\n      Other \"Vertical scroll bar, 1 page\" value=\"0%\" [369,115,30,676]\n    TabBar \"Tab Bar\" [0,791,402,83]\n      Button \"Home\" selected [68,795,94,54]\n        Image \"home\" id=house.fill [98,801,33,28]\n      Button \"Updates\" [154,795,94,54]\n        Image \"Two clockwise triangle-headed arrows rotated 90 degrees\" id=arrow.trianglehead.2.clockwise.rotate.90 [187,801,28,27]\n      Button \"Settings\" [240,795,94,54]\n        Image \"Gear shape, filled\" id=gearshape.fill [273,801,28,28]\n    Toolbar \"Toolbar\" [0,0,402,874]",
  "treeElements": 75,
  "treeNote": "XCTest XCUIApplication.snapshot() via xcodebuild test-without-building; frames in points.",
  "treeStatus": "ok",
  "url": "myapp://",
  "urlNote": null,
  "waitText": "Enter URL manually",
  "waitTextFound": true
}
```

`treeStatus` is `ok`, `skipped` (`--no-tree`), `unavailable` or `failed`;
`treeNote` says why. fast-ios never returns a guessed tree.

### How the tree is read, and its limits

The tree comes from a small XCTest UI-test bundle that fast-ios compiles once
per Xcode (about 9 s, cached in `~/Library/Caches/fast-ios/ax-runner`) and
runs with `xcodebuild test-without-building`. It calls
`XCUIApplication(bundleIdentifier:).snapshot()`: public API, headless, no
Simulator window. The same runner taps **Open** on the "Open in …?" prompt
that iOS 27 shows for `simctl openurl` with a custom scheme; without that
tap the link never reaches the app (`openPromptAccepted`).

Rejected: the macOS Accessibility API on the Simulator window needs the
Simulator app on screen and an Accessibility grant, so it is not headless.
Every other route (AXRuntime, idb's AccessibilityPlatformTranslation) is a
private framework.

Limits, measured on an M5 with Xcode 27.2 and iOS 27.0:

- **The first tree is slow, the next ones are not.** The first tree on a
  simulator waits for xcodebuild to start a test session (6 s median in the
  bench below; single runs ranged from 5 to 26 s). That session then stays
  up for 5 minutes after the last shot (`FASTIOS_SHOT_IDLE` changes it), and
  later trees take about 1 s. While it is up it costs one xcodebuild
  process on the Mac and the runner app in the simulator; it ends by itself
  when the simulator shuts down. `--no-session` starts and ends xcodebuild
  for every tree instead.
- **Tested runtimes.** The tree was not empty on iOS 26.5 (72 elements) and
  iOS 27.0 (75 elements), same app and screen, Xcode 27.2.
- **Default device set only.** xcodebuild finds simulators only in the
  default set, so with `--set` the tree is `unavailable`, `--wait <text>`
  falls back to a stable screen, and a deep-link prompt is not tapped
  (`urlNote` says so).
- **Stable is not ready.** A splash screen or a "loading" screen that holds
  still for a second, or only spins a small indicator, counts as settled. Use
  `--wait <text>` for the first real element; a large animation that never
  stops gives `screenStable: false` after the timeout.
- The prompt is matched by its English button title, Open.

### Shot speed and size

`fast-ios bench --scenario shot --repeat 5 --app <app>` printed this
(15 Nov 2026; Apple M5, 24 GB, macOS 27.0.1, Xcode 27.2; iPhone 18 Pro,
iOS 27.0; a React Native development build whose screen has a spinner;
medians of 5; memory pressure normal):

| Shot | Total | Tree | Screen settle | PNG |
|---|---:|---:|---:|---:|
| First shot with tree (runner starts) | 13.2 s | 6.0 s | 5.4 s | 1206 px, 149 KB |
| Next shot with tree (runner reused) | 7.3 s | 1.2 s | 5.3 s | 1206 px, 149 KB |
| Shot with tree, `--no-session` | 11.1 s | 6.1 s | 4.3 s | 1206 px, 150 KB |
| Shot without tree | 6.0 s | - | 5.2 s | 1206 px, 149 KB |
| Shot without tree, `--max-width 400` | 6.3 s | - | 4.7 s | 400 px, 47 KB |

Screen settle is the wait for this app's screen to stop changing and
depends on the app. `--max-width <px>` or `--scale <0-1>` shrinks the PNG
(ImageIO, on the Mac); `screenshotBytes`, `screenshotWidth` and
`pixelsPerPoint` (to map tree frames onto the PNG) are in the JSON.

## Grant permissions before launch

`run --grant <permission>` and `shot --grant <permission>` (repeatable)
answer permission prompts before the app starts, with `xcrun simctl privacy
grant`, so the first screen is the app and not a system alert.

What works, measured with [`scripts/privacy-probe`](scripts/privacy-probe)
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
2. **Map to services.** [`CapabilityMap.swift`](Sources/FastIOSCore/CapabilityMap.swift)
   is a data table. Each row is a trigger, the launchd labels it keeps, and a
   reason. For example: `NSPhotoLibraryUsageDescription` keeps `assetsd` and
   `assetsd.nebulad`; `aps-environment` or `remote-notification` keeps
   `apsd`; associated domains keep `swcd`; linking `StoreKit` keeps
   `storekitd` and Apple Media Services. Every other service in the
   [catalog](Sources/FastIOSCore/ServiceCatalog+Data.swift) is turned off.
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
[`NeverDisable.swift`](Sources/FastIOSCore/NeverDisable.swift). Turning
them off stops the simulator from starting, hangs app launch, or breaks
basic system UI. fast-ios leaves them out of every light set, and `off`
turns them back on if another tool turned them off. `assistantd` and
`gamed` are core processes; the Siri and game-controller services in the
table above are other labels, which are turned off.

## Full benchmark

Every number here comes from `fast-ios bench` on one Mac (Apple M5, 24 GB,
macOS 27.0.1, Xcode 27.2; iPhone 18 Pro, iOS 27.0; simslim 0.14.0), on
15 Nov 2026. Each run creates a new simulator in a separate set of
simulators, one at a time, and deletes it afterwards. Timings are medians
of 3 runs. Run `fast-ios bench` to measure your own Mac.

[simslim](https://github.com/MobAI-App/simslim) is an open-source command
line tool that turns off the same simulator services, by hand, one
simulator at a time. fast-ios started from its list of services (see
Credit), so it is the fairest comparison. "Full" is a simulator as Xcode
sets it up.

The runs were on different hours of one day, and the Mac was busier during
some of them, so compare rows within one table, not across tables.

**Run A: memory and start time, quiet Mac** (`fast-ios bench --repeat 3`,
raw output [`docs/bench/2026-11-15-boot.json`](docs/bench/2026-11-15-boot.json);
both tools turn off all 173 services here, since simslim cannot read an
app; memory pressure stayed normal):

| | Full | simslim | fast-ios |
|---|---|---|---|
| New simulator to light, started and ready | 22.6 s | 14.3 s | 13.5 s |
| Second start, to ready | 3.4 s | 2.4 s | 2.4 s |
| Processes, 3 min after start | 276 | 73 | 74 |
| Memory, 3 min after start | 2,853 MB | 605 MB | 613 MB |
| List simulators (`simslim list`, `fast-ios status`) | | 472 ms | 142 ms |

A tie with simslim: the three runs overlap (simslim 16.7, 13.3, 14.3 s;
fast-ios 16.8, 12.5, 13.5 s), and both turn off the same 173 services. Both
are much lighter than full. With all 173 off, memory is lower than the
829 MB at the top, which keeps 18 services for a real app.

**Run B: time until the app is running, busy Mac** (`fast-ios bench
--scenario app --repeat 3 --app <app>`, a real Expo development build,
raw output [`docs/bench/2026-11-15-template.json`](docs/bench/2026-11-15-template.json);
from nothing until `simctl launch` returns, which is when the app process
exists, not its first frame). Memory pressure stayed normal, but other work
was compiling on this Mac. These are the numbers at the top of this README
and on the website.

| How | Median | Runs |
|---|---|---|
| Full: `simctl create`, start, install, launch | 36.2 s | 36.2, 37.2, 34.9 |
| simslim: `simctl create`, `simslim on`, install, launch | 21.3 s | 24.2, 21.3, 19.6 |
| `fast-ios run`, first time, without a template | 26.4 s | 38.3, 26.4, 24.4 |
| `fast-ios run`, first time, from a template | 12.1 s | 19.8, 12.1, 9.5 |
| `fast-ios run`, next time, same build | 2.3 s | 4.5, 2.1, 2.3 |
| `fast-ios run`, next time, changed build | 1.8 s | 3.5, 1.8, 1.5 |
| Building the template (once per set, runtime and device type) | 32.6 s | 32.6 |

A template is a light simulator that fast-ios starts once and then copies,
so a new simulator skips its slow first start (3 s instead of 14 s in the
[feasibility test](docs/bench/2026-11-15-template-feasibility.md)). From a
template, the first run is the fastest new-simulator start here. It is not
faster every time: the slowest of the three (19.8 s) is about as fast as
simslim's fastest (19.6 s). Without a template, `fast-ios run` was slower
than simslim with its four manual commands.

**Run C: time until the app is running, quiet Mac, before templates
existed** (same command, raw output
[`docs/bench/2026-11-15-app.json`](docs/bench/2026-11-15-app.json)):

| How | Median | Runs |
|---|---|---|
| Full: `simctl create`, start, install, launch | 28.8 s | 27.3, 28.8, 31.4 |
| simslim: `simctl create`, `simslim on`, install, launch | 17.6 s | 17.6, 17.3, 17.9 |
| `fast-ios run`, first time, without a template | 18.8 s | 19.4, 18.8, 18.5 |
| `fast-ios run`, next time, same build | 1.4 s | 1.5, 1.4, 1.4 |
| `fast-ios run`, next time, changed build | 1.5 s | 1.3, 1.5, 1.5 |

"Next time" reuses the running light simulator and only installs and
launches. A changed build costs about the same as the same build, because
`simctl install` copies the whole 220 MB bundle every time: 1.4 to 2.8 s on
a simulator that has been up a while, whatever changed
([`docs/bench/2026-11-15-install.md`](docs/bench/2026-11-15-install.md)).
A simulator an agent keeps running itself, with simslim or without, is just
as fast to reinstall; what fast-ios adds is that the pool does it for many
agents at once, with the memory check, ownership and cleanup.

**Run D: many agents at once** (`fast-ios bench --scenario parallel
--agents 3 --repeat 2 --inject-fault`, raw output
[`docs/bench/2026-11-15-parallel.json`](docs/bench/2026-11-15-parallel.json);
agent 1's first start was made to hang past a 1 s deadline, to test
replacement): 3 of 3 agents launched the app in both rounds, and each round
retired and replaced 1 simulator (the hung one; deleted, since fast-ios
created it). Wall time 56.8 s and 63.9 s. Memory pressure stayed normal;
lowest available memory 6.9 GB.

**What simslim has no command for** (facts, not speed claims):

- *A light set read from the built app.* fast-ios read this app's set in
  0.1 s: 18 services kept, 155 off, each kept one with its reason. simslim
  takes a hand-written `--profile` file or `--except`/`--keep` flags.
- *Turning services back on when the app calls them.* fast-ios sees the app
  fail to reach a service that is off and turns it on with no restart (see
  Self-repair; the benchmark does not time it, since the app has to call the
  service). simslim's `enable` turns services on live when you name them.

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

## Uninstall

You do every step. Run each command in any folder.

1. Turn fast-ios off:

   ```bash
   fast-ios off
   ```

   Every simulator goes back to full, and the background helper
   (`~/Library/LaunchAgents/dev.fast-ios.auto.plist`) is stopped and
   deleted. If you skip this, the helper keeps making new simulators light
   after the app is gone.
2. In the menu-bar app, turn off "Open at login", then click Quit. If the
   app is already gone, remove "fast-ios" in System Settings > General >
   Login Items instead. Otherwise macOS keeps a login item that points at
   nothing.
3. Delete the simulators fast-ios created for leases and templates (names
   start with `fast-ios-lease-` or `fast-ios-template-`):

   ```bash
   xcrun simctl list devices --json | jq -r '.devices[][] | select(.name | test("^fast-ios-(lease|template)-")) | .udid' | xargs -n1 xcrun simctl delete
   ```

   This deletes only those simulators; yours keep their names and are not
   touched. Skip it and they stay in Xcode's list, using disk space.
4. Remove the command. If you installed with Homebrew:

   ```bash
   brew uninstall fast-ios
   ```

   Otherwise, remove the link the script or the app made:

   ```bash
   link=$(command -v fast-ios) && [ -L "$link" ] && rm "$link"
   ```

   This removes only a link, never a real file.
5. Move the app to the Trash: drag `fast-ios` from Applications (or
   `~/Applications`) to the Trash.
6. Delete what fast-ios saved:

   ```bash
   rm -rf ~/Library/Application\ Support/fast-ios ~/Library/Caches/fast-ios ~/Library/Logs/fast-ios.log
   ```

   That is the state folder (light sets, leases, what self-repair learned),
   the compiled screen-tree reader, and the helper's log. Do this after
   step 1: the helper writes to the log while it runs.
7. Delete the app's settings:

   ```bash
   defaults delete dev.fast-ios.app
   ```

   It answers "Domain 'dev.fast-ios.app' not found" if the app never saved
   any; that is fine.

Left behind on purpose: each simulator's
`/private/var/tmp/com.apple.CoreSimulator.SimDevice.<UDID>/disabled.plist`
belongs to CoreSimulator, and after `fast-ios off` it holds no entries
fast-ios turned off. Screenshots and other temporary files are in the macOS
temporary folder, which macOS clears by itself.

## Tests

```bash
swift test                                     # unit tests, no simulator, under a second
scripts/integration.sh path/to/MyApp.app       # run, shot, heal, release, off on a throwaway simulator
```

The unit tests (Swift Testing, `tests/FastIOSCoreTests`) cover the capability
map, the overrides file and its atomic write, the never-disable list, light
set and lease state, heal's log parsing with its cool-down and cap, and the
JSON contract of every MCP tool. They set `FASTIOS_STATE_DIR` to a temp
folder, so they never read or write your real fast-ios state.

`scripts/integration.sh` creates a new set of simulators and state folder,
lets fast-ios create the only simulator in it, refuses to act on any UDID it
did not create, and deletes everything at the end (about 1 minute). CI
(`.github/workflows/ci.yml`) builds with warnings as errors and runs the unit
tests on pull requests; it does not run the integration script.

## Credit

fast-ios follows [simslim](https://github.com/MobAI-App/simslim) (MIT,
Copyright (c) 2026 Interlap): its launchd-override approach, the overrides
path and plist shape, the never-disable list, and the service catalog with
its categories, descriptions and downsides, which fast-ios copies as-is from
simslim commit `7e374b3` (see
[`THIRD_PARTY_SIMSLIM_LICENSE`](THIRD_PARTY_SIMSLIM_LICENSE)). fast-ios adds
the light set read from the built app, leases, `shot`, self-repair, the MCP
server and skill, a Swift core, the background helper and a SwiftUI
menu-bar app.

The tiger is from [page-mascot](https://github.com/nilbuild/page-mascot) by
Kamran Ahmed (MIT). See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## License

MIT. See [LICENSE](LICENSE).
