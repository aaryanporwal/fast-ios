# fast-ios JSON output

Every command takes `--json`. stdout is one JSON object (`watch` and `heal`:
one object per line). Every object has `schemaVersion` (now 1); fields are
only added, never renamed or removed, within a version. Fields that can be
unknown are `null`, never missing. Errors are JSON on stdout with exit code 1;
`error.code` is one of `usage`, `invalid_arguments`, `simulator`, `app`,
`command_failed`, `internal`. A refused `lease` is an answer, not an error:
`"status": "refused"` with exit code 2.

Some field names come from before fast-ios settled on the words "light"
and "full" for people. They stay, because fields are never renamed within
a version: `"slim": true` means the simulator is light, a `profile` is the
light set for one app (`"general"` when no app is known), and `"full"`
as a profile name means every optional service is off. When an agent
reports to a person, it should say light and full.

The samples below are from real runs on 15 Nov 2026 (iPhone 18 Pro, iOS
27.0, a private device set). Long arrays are cut to their first items and
paths are shortened. The app name and bundle id are replaced with neutral
samples (`MyApp.app`, `com.example.myapp`); nothing else is changed.

`fast-ios status --json`

```json
{
  "deviceSet" : "/path/to/devset",
  "schemaVersion" : 1,
  "simulators" : [
    {
      "deviceType" : "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
      "disabledCount" : 155,
      "memoryBytes" : 572194816,
      "name" : "fastios-mcp-test",
      "processes" : 68,
      "profileName" : "auto: MyApp.app",
      "runtime" : "iOS 27.0",
      "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
      "slim" : true,
      "state" : "Booted",
      "udid" : "4FB5BF30-DBDB-4F07-960E-26C048C38B39"
    }
  ]
}
```

`fast-ios profile MyApp.app --json`

```json
{
  "app": ".../Debug-iphonesimulator/MyApp.app",
  "bundleIdentifier": "com.example.myapp",
  "catalogCount": 173,
  "matchedRules": [
    {
      "keep": ["com.apple.assetsd", "com.apple.assetsd.nebulad"],
      "reason": "Photo picker and PHPhotoLibrary read the library through assetsd.",
      "trigger": "Info.plist NSPhotoLibraryUsageDescription"
    }
  ],
  "neverDisabled": ["com.apple.CoreSimulator.bridge", "com.apple.SpringBoard", "com.apple.UserEventAgent-System"],
  "profile": {
    "appPath": ".../Debug-iphonesimulator/MyApp.app",
    "disable": ["com.apple.ClipServices.clipserviced", "com.apple.FamilyControlsAgent", "com.apple.GameController.gamecontrollerd"],
    "keep": {
      "com.apple.amsaccountsd": [
        "links StoreKit.framework: StoreKit purchases and the payment sheet need storekitd and Apple Media Services."
      ]
    },
    "name": "auto: MyApp.app"
  },
  "schemaVersion": 1
}
```

`fast-ios slim 4FB5BF30-DBDB-4F07-960E-26C048C38B39 --app MyApp.app --json`

```json
{
  "booted": true,
  "disabled": ["com.apple.ClipServices.clipserviced", "com.apple.FamilyControlsAgent", "com.apple.GameController.gamecontrollerd"],
  "log": [
    "Shutting down fastios-mcp-test to rewrite its launchd overrides…",
    "Wrote 155 disables and 0 re-enables to /private/var/tmp/com.apple.CoreSimulator.SimDevice.4FB5BF30-DBDB-4F07-960E-26C048C38B39/disabled.plist",
    "Booting fastios-mcp-test…"
  ],
  "notHonoured": [],
  "profile": {
    "appPath": ".../Debug-iphonesimulator/MyApp.app",
    "disableCount": 155,
    "keepCount": 18,
    "name": "auto: MyApp.app"
  },
  "reenabled": [],
  "schemaVersion": 1,
  "simulator": {
    "deviceType": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
    "name": "fastios-mcp-test",
    "runtime": "iOS 27.0",
    "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
    "state": "Booted",
    "udid": "4FB5BF30-DBDB-4F07-960E-26C048C38B39"
  },
  "verified": true
}
```

`fast-ios measure 4FB5BF30-DBDB-4F07-960E-26C048C38B39 --json`

```json
{
  "processCount": 63,
  "processes": [
    { "bytes": 66554544, "name": "SpringBoard", "pid": 21553 },
    { "bytes": 33474552, "name": "diagnosticd", "pid": 21611 }
  ],
  "schemaVersion": 1,
  "simulator": { "deviceType": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", "name": "fastios-mcp-test", "runtime": "iOS 27.0", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "state": "Booted", "udid": "4FB5BF30-DBDB-4F07-960E-26C048C38B39" },
  "totalBytes": 490948992
}
```

`fast-ios off 4FB5BF30-DBDB-4F07-960E-26C048C38B39 --json`

```json
{
  "alreadyStock": false,
  "booted": true,
  "log": [
    "Shutting down fastios-mcp-test to rewrite its launchd overrides…",
    "Wrote 0 disables and 155 re-enables to /private/var/tmp/com.apple.CoreSimulator.SimDevice.4FB5BF30-DBDB-4F07-960E-26C048C38B39/disabled.plist",
    "Booting fastios-mcp-test…"
  ],
  "reenabled": ["com.apple.ClipServices.clipserviced", "com.apple.FamilyControlsAgent", "com.apple.GameController.gamecontrollerd"],
  "schemaVersion": 1,
  "simulator": { "deviceType": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", "name": "fastios-mcp-test", "runtime": "iOS 27.0", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "state": "Booted", "udid": "4FB5BF30-DBDB-4F07-960E-26C048C38B39" }
}
```

`fast-ios catalog --json`

```json
{
  "categories": [
    {
      "approxMemoryMB": 675,
      "description": "Home and lock screen posters, widgets, and Live Activities.",
      "downside": "Home and Lock Screen widgets, wallpaper posters, and Live Activities stop updating.",
      "id": "widgets",
      "name": "Widgets & Wallpaper",
      "services": [
        { "description": "Renders Home and Lock Screen wallpaper scenes.", "label": "com.apple.PosterBoard" }
      ]
    }
  ],
  "neverDisabled": [
    { "label": "com.apple.CoreSimulator.bridge", "reason": "The host-to-simulator bridge that simctl uses." }
  ],
  "schemaVersion": 1,
  "slimmableCount": 173
}
```

`fast-ios watch --full --json` (one line per event; it runs until stopped)

```json
{"disabledCount":null,"event":"watching","message":null,"profile":{"appPath":null,"disableCount":173,"keepCount":0,"name":"full"},"schemaVersion":1,"setFolders":["/path/to/watchset"],"udid":null}
{"disabledCount":173,"event":"slimmed","message":null,"profile":null,"schemaVersion":1,"setFolders":null,"udid":"9FABFD83-7C16-4575-B79A-BFC8724F55FE"}
```

`event` is `watching`, `slimmed`, `skipped` (the new simulator was already
booting) or `error`. `watch` is not an MCP tool, because it never returns.

`fast-ios help --json` prints `{"schemaVersion", "usage", "jsonCommands"}`.

An error, `fast-ios measure nope --json` (exit code 1):

```json
{
  "error" : {
    "code" : "simulator",
    "message" : "No simulator matches \"nope\"."
  },
  "schemaVersion" : 1
}
```

`fast-ios shot` output is in the [README](../README.md#shot-see-the-screen-in-one-call).

## App cache

`run --json` and `shot --json` have `appCache`: `null` when the cache was
not used (nothing stored for the project and no `--build`), else an object.
`status` is `hit` (a stored app was reused), `built` (this call ran
`--build` and stored the app), `waited` (another agent built it while this
one waited) or `miss` (no stored app matched and nothing was built; the
local build was used). From a real run on 17 Nov 2026, two worktrees of a
sample app started 1 s apart, this is the one that waited:

```json
"appCache": {
  "builtAt": "2026-11-17T10:17:51Z",
  "fingerprint": "0a54fa56d8d0ff0bd9c7cc4c4628fe7d665c31ada2d81b49cdf18eca4e846495",
  "kind": "files",
  "message": "Another agent built this app while this one waited 28.7 s; reusing it.",
  "savedSeconds": 0.8,
  "status": "waited"
}
```

`savedSeconds` is the stored build's time minus what this call spent
(fingerprinting, or waiting); `null` when the build was not timed.

`fast-ios apps --json` (the same run; one of two entries shown, path
shortened). `why` is filled by `apps why <project>`: `fingerprint`, `kind`,
`hit`, `comparedWith`, and the input names in `changed`, `added` and
`removed`.

```json
{
  "action": "list",
  "apps": [
    {
      "app": "/path/to/apps/0a54fa56d8d0ff0bd9c7cc4c4628fe7d665c31ada2d81b49cdf18eca4e846495/SampleXcode.app",
      "appName": "SampleXcode.app",
      "architectures": ["x86_64", "arm64"],
      "buildSeconds": 29.5,
      "builtAt": "2026-11-17T10:17:51Z",
      "bundleIdentifier": "dev.example.samplexcode",
      "configuration": "Debug",
      "fingerprint": "0a54fa56d8d0ff0bd9c7cc4c4628fe7d665c31ada2d81b49cdf18eca4e846495",
      "kind": "files",
      "lastUsedAt": "2026-11-17T10:26:39Z",
      "projectID": "git:3ea10e9cfc13:.",
      "projectName": "sample-xcode-b",
      "sizeBytes": 10264576,
      "storedAt": "2026-11-17T10:17:51Z",
      "variant": null,
      "xcodeVersion": "27.2 (27B52)"
    }
  ],
  "folder": "/path/to/apps",
  "maxBytes": 10737418240,
  "message": "2 stored apps.",
  "schemaVersion": 1,
  "totalBytes": 213372928,
  "why": null
}
```

The real run printed `29.5258709192276` and `0.8002629280090332`; fast-ios
now rounds both to tenths.
