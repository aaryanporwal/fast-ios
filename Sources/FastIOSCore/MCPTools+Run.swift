import Foundation

extension MCPTools {
    static let run = MCPTool(
        name: "run", title: "Run an app on a light simulator",
        description: "The one call to try an app: lease a simulator from the fast-ios pool (reuses a free booted one, else boots or creates one), make it light for the app, install, launch, and return the UDID. When the Mac is short of memory it answers at once with error code memory_pressure, what uses the memory and the choices (reuse a running simulator with simulator, start anyway with maxPressure warning, or shut one down); pass waitForMemory to wait instead. Without app, finds the newest simulator build for the project in folder (Xcode DerivedData, ios/build, build/). For a project folder, the app cache reuses a stored build when the project's fingerprint matches (Expo: native inputs only, so JavaScript changes still hit); with build, a miss runs that command once, stores the app, and other agents missing on the same fingerprint wait for it (see appCache in the result and the apps tool). The lease ends after ttl or when your process exits; end it early with release.",
        inputSchema: Schema.object([
            "app": Schema.string("Built .app, or a folder that contains a simulator build. Omit to find the build automatically."),
            "folder": Schema.string("Project folder to search when app is omitted. Default: the current folder."),
            "url": Schema.string("URL to open after launch (deep link or universal link)."),
            "keep": keepArg,
            "grant": grantArg,
            "runtime": Schema.string("Runtime identifier or name such as \"iOS 27.0\". Default: newest iOS."),
            "deviceType": Schema.string("Device type identifier or name. Default: newest iPhone Pro."),
            "ttl": Schema.string("Lease length such as \"30m\", \"2h\" or \"90s\". Default 30m."),
            "simulator": Schema.string("Use this simulator instead of leasing one. Only one you created."),
            "noLaunch": Schema.boolean("Install only; do not launch."),
            "maxPressure": Schema.string("Highest memory pressure at which a new boot may start: normal (default) or warning."),
            "waitForMemory": Schema.string("How long to wait for memory when the Mac is short of it, such as \"5m\". Default 0: answer at once with the reason and the choices."),
            "timeout": Schema.string("Old name for waitForMemory."),
            "deviceSet": deviceSetArg,
        ].merging(cacheArgs) { a, _ in a }),
        outputSchema: Schema.object([
            "schemaVersion": Schema.integer(), "udid": Schema.string(), "name": Schema.string(),
            "app": Schema.string(), "appSource": Schema.string(), "bundleIdentifier": Schema.nullable("string"),
            "profile": profileSummary, "simulatorSource": Schema.string("leased or given"),
            "leaseExpiresAt": Schema.nullable("string"), "launched": Schema.boolean(),
            "pid": Schema.nullable("integer"), "url": Schema.nullable("string"),
            "granted": Schema.array(Schema.string(), "Permissions granted before launch with simctl privacy."),
            "cloned": Schema.boolean("The leased simulator was copied from a light template."),
            "replaced": replacedSchema,
            "appCache": appCacheSchema,
            "seconds": Schema.object(["waited": Schema.number(), "simulator": Schema.number(), "install": Schema.number(),
                                      "launch": Schema.number(), "total": Schema.number()],
                                     required: ["waited", "simulator", "install", "launch", "total"]),
            "log": strings,
        ], required: ["schemaVersion", "udid", "name", "app", "appSource", "bundleIdentifier", "profile",
                      "simulatorSource", "leaseExpiresAt", "launched", "pid", "url", "granted", "seconds", "log"]),
        annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false]
    ) { args in
        var r = RunRequest()
        r.app = args.optionalString("app")
        if let f = args.optionalString("folder") { r.folder = f }
        r.url = args.optionalString("url")
        r.keep = args.strings("keep")
        r.runtime = args.optionalString("runtime")
        r.deviceType = args.optionalString("deviceType")
        if let ttl = args.optionalString("ttl") {
            guard let t = FastIOSCommands.parseDuration(ttl) else { throw InvalidArguments("ttl must look like 90s, 30m or 2h; got \(ttl).") }
            r.ttl = t
        }
        r.simulator = args.optionalString("simulator")
        r.launch = !args.bool("noLaunch")
        if let p = args.optionalString("maxPressure") {
            guard ["normal", "warning"].contains(p) else { throw InvalidArguments("maxPressure must be normal or warning; got \(p).") }
            r.policy = AdmissionPolicy(maxPressure: p)
        }
        if let v = try FastIOSCommands.memoryWait(args) { r.memoryWait = v }
        r.grant = try Privacy.validate(args.strings("grant"))
        r.cache = try cacheRequest(args)
        return try await AppRunner.run(r)
    }

    static let pool = MCPTool(
        name: "pool", title: "Keep light simulators warm",
        description: "Keep `size` light simulators booted and free in the fast-ios pool, so the next run or lease skips the boot and only installs and launches. Boots only while memory allows (the lease admission rules); free ones are shut down again while memory is short or after the idle limit (idle, default 30m); size 0 shuts down every idle pool simulator. The setting persists. Pass app so warm simulators already have that app's profile; a different profile means a reboot at lease time.",
        inputSchema: Schema.object([
            "size": Schema.integer("Free booted simulators to keep. 0 shuts the idle ones down."),
            "app": Schema.string("Make the warm simulators light for this app (a .app or folder). Default: the last derived profile."),
            "full": Schema.boolean("Turn off the whole catalog instead."),
            "runtime": Schema.string("Runtime such as \"iOS 27.0\". Default: newest with an iPhone Pro."),
            "deviceType": Schema.string("Device type. Default: newest iPhone Pro."),
            "maxPressure": Schema.string("Highest memory pressure at which a boot may start: normal (default) or warning."),
            "timeout": Schema.string("How long to wait for memory per boot, such as \"60s\". Default 60s."),
            "idle": Schema.string("How long a free, running pool simulator is kept before it is shut down, such as \"30m\" (the default). Persists."),
            "deviceSet": deviceSetArg,
        ], required: ["size"]),
        outputSchema: Schema.object([
            "schemaVersion": Schema.integer(), "size": Schema.integer(), "free": strings, "booted": strings,
            "shortBecause": Schema.nullable("string"),
            "memory": Schema.object(["availableMB": Schema.integer(), "totalMB": Schema.integer(), "pressure": Schema.string()],
                                    required: ["availableMB", "totalMB", "pressure"]),
            "log": strings,
        ], required: ["schemaVersion", "size", "free", "booted", "shortBecause", "memory", "log"]),
        annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        positional: []
    ) { args in
        guard case .int(let n)? = args.raw["size"], n >= 0, n <= 8 else { throw InvalidArguments("size must be 0 to 8.") }
        let (profile, _) = try await FastIOSCommands.resolveProfile(app: args.optionalString("app"), keep: [], full: args.bool("full"))
        var policy = AdmissionPolicy()
        if let p = args.optionalString("maxPressure") {
            guard ["normal", "warning"].contains(p) else { throw InvalidArguments("maxPressure must be normal or warning; got \(p).") }
            policy = AdmissionPolicy(maxPressure: p)
        }
        var timeout: TimeInterval = 60
        if let t = args.optionalString("timeout") {
            guard let v = FastIOSCommands.parseDuration(t) else { throw InvalidArguments("timeout must look like 60s or 5m; got \(t).") }
            timeout = v
        }
        var idleMinutes: Int?
        if let s = args.optionalString("idle") {
            guard let v = FastIOSCommands.parseDuration(s), v >= 60 else { throw InvalidArguments("idle must be at least 1m, such as 30m or 2h; got \(s).") }
            idleMinutes = Int(v / 60)
        }
        return try await Pool.set(size: Int(n), profile: profile, runtime: args.optionalString("runtime"),
                                  deviceType: args.optionalString("deviceType"), policy: policy, timeout: timeout,
                                  idleMinutes: idleMinutes)
    }

    static let doctor = MCPTool(
        name: "doctor", title: "Check this Mac for fast-ios",
        description: "Check Xcode, iOS runtimes, a simslim watch agent that would fight fast-ios, memory pressure, disk space and the fast-ios state file. Each problem comes with a fix line. Read-only.",
        inputSchema: Schema.object([:]),
        outputSchema: Schema.object([
            "schemaVersion": Schema.integer(), "ok": Schema.boolean(),
            "checks": Schema.array(Schema.object([
                "id": Schema.string(), "status": Schema.string("ok, warn or fail"),
                "summary": Schema.string(), "fix": Schema.nullable("string"),
            ], required: ["id", "status", "summary", "fix"])),
            "canStartSimulator": Schema.boolean("A new simulator could start now: the rule lease and run use."),
        ], required: ["schemaVersion", "ok", "checks"]),
        annotations: readOnly
    ) { _ in await Doctor.run() }
}
