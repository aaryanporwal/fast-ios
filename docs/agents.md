# fast-ios for coding agents

Back to the [README](../README.md).

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
[`skills/fast-ios/SKILL.md`](../skills/fast-ios/SKILL.md), tells an agent when
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
[`tests/mcp-client.ts`](../tests/mcp-client.ts) (needs `bun` and a simulator you
created in a separate set).

**JSON.** stdout is one JSON object (`watch` and `heal`: one per line) with
`schemaVersion` (now 1). Errors are JSON on stdout with an `error.code` and
exit code 1 (64 for bad arguments). A refused `lease` exits 2 with
`"status": "refused"`. Some field names come from before the words light
and full: `"slim": true` means light. Real samples for every command:
[`docs/json-output.md`](json-output.md).

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


Speed and size of `shot`: [benchmarks.md](benchmarks.md#shot-speed-and-size).
