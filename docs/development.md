# Development

Back to the [README](../README.md).

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

## The demo recording

The README's GIF is recorded with [vhs](https://github.com/charmbracelet/vhs)
from [`demo/demo.tape`](demo/demo.tape), with a sample app built from
[`demo/MyApp`](demo/MyApp), in a separate set of simulators. From the
repository root:

```bash
docs/demo/prepare.sh && vhs docs/demo/demo.tape && docs/demo/teardown.sh
```

What the recording shows and why its numbers differ from the tables:
[benchmarks.md](benchmarks.md#the-demo-recording).
