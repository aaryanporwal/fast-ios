# Benchmarks

Back to the [README](../README.md). Every number here comes from `fast-ios bench` or `fast-ios measure`; the raw output is in [`bench/`](bench/).

## Memory

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

## Time until the app is running

| Time until the app is running | Median |
|---|---|
| Full simulator: create, start, install, launch | 36.2 s |
| `fast-ios run`, first time | 12.1 s |
| `fast-ios run`, next time | 2.3 s |

From one run of `fast-ios bench --scenario app --repeat 3` with a real Expo
app, measured until the app's process starts. `fast-ios run` keeps a light
simulator running after you are done, so the next run only installs and
launches. Every row, the comparison with simslim and what to keep in mind:

## The demo recording

A real recording, made with [vhs](https://github.com/charmbracelet/vhs)
from [`docs/demo/demo.tape`](demo/demo.tape) on the same Mac, with a
sample app built from [`docs/demo/MyApp`](demo/MyApp). It is a
different run from the tables, so its numbers differ: the full simulator
used 3,017 MB here. The "about 4.2 GB" on the last screen counts two
running light simulators: the one shown and the one `fast-ios run` started.
Two idle waits are cut: 3 s while the stopped simulator is made light, and
150 s while memory settles. Reproduce it with `docs/demo/prepare.sh && vhs
docs/demo/demo.tape && docs/demo/teardown.sh`.

## Every run

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
raw output [`docs/bench/2026-11-15-boot.json`](bench/2026-11-15-boot.json);
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
829 MB under [Memory](#memory), which keeps 18 services for a real app.

**Run B: time until the app is running, busy Mac** (`fast-ios bench
--scenario app --repeat 3 --app <app>`, a real Expo development build,
raw output [`docs/bench/2026-11-15-template.json`](bench/2026-11-15-template.json);
from nothing until `simctl launch` returns, which is when the app process
exists, not its first frame). Memory pressure stayed normal, but other work
was compiling on this Mac. These are the numbers in the README
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
[feasibility test](bench/2026-11-15-template-feasibility.md)). From a
template, the first run is the fastest new-simulator start here. It is not
faster every time: the slowest of the three (19.8 s) is about as fast as
simslim's fastest (19.6 s). Without a template, `fast-ios run` was slower
than simslim with its four manual commands.

**Run C: time until the app is running, quiet Mac, before templates
existed** (same command, raw output
[`docs/bench/2026-11-15-app.json`](bench/2026-11-15-app.json)):

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
([`docs/bench/2026-11-15-install.md`](bench/2026-11-15-install.md)).
A simulator an agent keeps running itself, with simslim or without, is just
as fast to reinstall; what fast-ios adds is that the pool does it for many
agents at once, with the memory check, ownership and cleanup.

**Run D: many agents at once** (`fast-ios bench --scenario parallel
--agents 3 --repeat 2 --inject-fault`, raw output
[`docs/bench/2026-11-15-parallel.json`](bench/2026-11-15-parallel.json);
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

## Shot speed and size

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

## App cache

| Sample project (17 Nov 2026, Apple M5, busy Mac) | Compile | Reuse |
|---|---|---|
| Expo SDK 58 with `expo-dev-client` | 254 s | 0.90 s |
| SwiftUI app, 62 Swift files | 70.9 s | 0.30 s |

From `fast-ios bench --scenario build --repeat 5` on small sample apps made
for the check, not real apps. Install and launch are not included: they
cost the same either way.

Rules and evidence: [app-cache.md](app-cache.md).
