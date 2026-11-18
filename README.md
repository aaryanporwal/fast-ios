<img src=".github/tiger.png" width="120" alt="The fast-ios tiger">

# fast-ios

**iOS simulators that need a third of the memory.**

[![CI](https://github.com/aaryanporwal/fast-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/aaryanporwal/fast-ios/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/github/license/aaryanporwal/fast-ios)](LICENSE)

<img src="docs/demo/fast-ios-demo.gif" width="880" alt="Terminal: an iPhone 18 Pro simulator running full uses 3,108 MB; fast-ios on; after a restart the same simulator is light and uses 748 MB.">

<sub>A real recording on an Apple M5 Mac; the restart and 200 s of waiting for memory to settle are cut. [How it is made](docs/benchmarks.md#the-demo-recording).</sub>

An iPhone simulator starts close to 280 background processes and uses
almost 3 GB of memory, mostly for things your app never touches: widgets,
Siri, iCloud, Maps. fast-ios turns those off before the simulator starts.
It is for iOS developers on a Mac, and for coding agents that run several
simulators at once.

A simulator is **light** when fast-ios has turned off the services it does
not need, and **full** when every service runs, as Xcode sets it up. When
an app calls a service that is off, such as the photo library, fast-ios
turns it back on within a few seconds and keeps it on for that app.
[How it works](docs/how-it-works.md).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/aaryanporwal/fast-ios/main/packaging/install.sh | bash
```

This installs the menu-bar app and the `fast-ios` command, and asks for no
password. [What the script does](packaging/install.sh), and the other ways
in: Homebrew (`brew install aaryanporwal/fast-ios/fast-ios`) or the DMG.
Details: [docs/install.md](docs/install.md).

## Quick start

```bash
fast-ios on     # every simulator light from now on
fast-ios        # is it on, what is running, what you save, what to do next
fast-ios off    # every simulator back to full
```

Keep using Xcode, Expo or `simctl` exactly as before. Stopped simulators
become light at once, a running one at its next start, and new ones from
their first start. The menu-bar app's "Keep simulators light" switch does
the same as `fast-ios on` and `fast-ios off`.

To open your app on a light simulator, build it once for the simulator,
then run this in the project folder:

```bash
fast-ios run
```

## For coding agents

Five agents starting five full simulators is how a Mac runs out of memory.
fast-ios gives each agent a light simulator from one shared pool, waits when
memory is short, and takes it back when the agent is done. Every command
takes `--json`.

```bash
fast-ios run --app MyApp.app               # opens your app on a light simulator
fast-ios shot --app MyApp.app --udid <ID>  # saves a screenshot and what is on screen
fast-ios release <ID>                      # gives the simulator back
```

`run` prints the simulator's ID; pass it to `shot` and `release`. The form
for scripts, which keeps the ID in a variable, is in
[docs/agents.md](docs/agents.md).

Use `run` when the agent runs your app, and `lease` when it tests with its
own tools. fast-ios also has an MCP server (`fast-ios mcp`) and a skill:

```bash
claude mcp add --scope user fast-ios -- fast-ios mcp
```

Setup for Claude Code and Codex, the skill, a block to paste into
`AGENTS.md`, and `shot`: [docs/agents.md](docs/agents.md).

## Measured

| One iPhone 18 Pro simulator, iOS 27.0 | Full | Light |
|---|---|---|
| Memory used | 2,845 MB | 829 MB |
| Background processes | 277 | 93 |
| Time until the app is running, first time | 36.2 s | 12.1 s |
| Time until the app is running, next time | | 2.3 s |

Apple M5, Xcode 27.2, a real Expo app. Memory and processes: one
measurement 3 minutes after the simulator started (`fast-ios measure`).
Times: medians of 3 runs of `fast-ios bench --scenario app`. Your memory
number depends on what your app uses. Every run, the comparison with
simslim, and how to measure your own Mac:
[docs/benchmarks.md](docs/benchmarks.md).

## Requirements

- macOS 15 or newer, with Xcode
- An iOS 18.5 or newer simulator runtime
- To compile from source: Swift 6.3 or newer (Xcode 26.6 or newer)

## Remove it

```bash
fast-ios off         # every simulator back to full; the background helper is removed
fast-ios uninstall   # also deletes fast-ios's files, and says what is left for you
```

`fast-ios uninstall --dry-run` lists what it would remove. Every file, by
hand: [docs/uninstall.md](docs/uninstall.md).

## Documentation

- [Commands](docs/commands.md): every command, `run`, the app cache,
  keeping a service on, and permissions `--grant` answers
- [For coding agents](docs/agents.md): `run` and `lease`, MCP server,
  skill, leases, `shot`
- [How it works](docs/how-it-works.md): light and full, self-repair, what
  is never turned off, limits
- [Benchmarks](docs/benchmarks.md): the method and every run
- [App cache](docs/app-cache.md): reuse a built app across git worktrees
- [JSON output](docs/json-output.md): a real sample for every command
- [Install](docs/install.md) and [Uninstall](docs/uninstall.md)
- [Development](docs/development.md): tests and the demo recording

## License and credits

MIT. See [LICENSE](LICENSE).

fast-ios follows [simslim](https://github.com/MobAI-App/simslim) (MIT,
Copyright (c) 2026 Interlap): its way of turning off simulator services,
the list of services it never turns off, and the service catalog, which
fast-ios copies from simslim commit `7e374b3` (see
[`THIRD_PARTY_SIMSLIM_LICENSE`](THIRD_PARTY_SIMSLIM_LICENSE)). fast-ios
adds the light set read from your built app, self-repair, the shared pool
for agents, `shot`, the MCP server and skill, and the menu-bar app.

The tiger is from [page-mascot](https://github.com/nilbuild/page-mascot) by
Kamran Ahmed (MIT). See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
