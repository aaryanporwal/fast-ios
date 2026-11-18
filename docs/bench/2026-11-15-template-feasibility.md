# Slim template feasibility (15 Nov 2026)

Question: can a new pool simulator start from a prepared slim simulator
faster than create plus first boot?

Set-up: Apple M5, 24 GB, macOS 27.0.1, Xcode 27.2; iPhone 18 Pro, iOS 27.0;
a private device set; the same Expo development build as the other bench
files. Memory pressure normal. Timed by hand with a monotonic clock, one
simulator booted at a time (the clones stayed booted until the shared-state
check below).

Template: `simctl create`, the app's slim overrides, first boot
(`bootstatus -b`), 20 s wait, shutdown: 45.4 s including the wait.

| Round | Fresh: slim + boot | install | launch | Clone: `simctl clone` | slim + boot | install | launch |
|---|---|---|---|---|---|---|---|
| 1 | 14.18 s | 4.30 s | 0.37 s | 2.16 s | 2.93 s | 5.34 s | 0.35 s |
| 2 | 14.36 s | 4.67 s | 0.32 s | 2.17 s | 3.03 s | 5.21 s | 0.45 s |
| 3 | 18.85 s | 4.14 s | 0.44 s | 2.55 s | 3.25 s | 8.56 s | 0.38 s |

The clone boots in about 3 s instead of 14 to 19 s: first-boot setup does
not run again. Each clone started with no overrides (fast-ios wrote all 155
again), which confirms that `clone` drops them.

Shared state, checked on the three booted clones:

- `SIMULATOR_UDID` and `device.plist` UDID differ per clone and from the
  template.
- Each clone has its own data folder and its own app data container.
- A file written into clone 1's app `Documents` folder did not appear in
  clones 2 or 3.
- The template's overrides file was unchanged (155 entries).
- Not checked: keychain items and identifierForVendor. The template never
  has an app installed, so there is no app data or network cache to copy
  (the case in Stack Overflow 79842382 involved a cloned simulator that had
  run the app).

Decision: build it. `lease` clones the template when one is ready and
builds one in the background after a plain create.
