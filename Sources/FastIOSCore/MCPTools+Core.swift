import Foundation

// The tools for the commands in fast-ios v1. Output schemas mirror the types
// in JSONOutput.swift; tests/mcp-client.ts checks every response against them.

extension MCPTools {
    static let simulatorArg = Schema.string(
        "A simulator UDID, a unique simulator name, or \"booted\" (exactly one booted simulator).")
    static let deviceSetArg = Schema.string(
        "Path of a custom CoreSimulator device set (simctl --set). Omit for the default set.")
    static let grantArg = Schema.array(Schema.string(),
        "Permissions to grant before launch with simctl privacy, so no prompt appears. " + Privacy.helpLine)
    static let keepArg = Schema.array(Schema.string(),
        "Services to keep on: a category id such as \"widgets\", a category name such as \"Widgets & Wallpaper\", or a launchd label such as com.apple.chronod. Unknown names are refused. See the catalog tool.")
    static let strings = Schema.array(Schema.string())

    static let simulatorRef = Schema.object([
        "udid": Schema.string(), "name": Schema.string(),
        "runtime": Schema.string("Such as \"iOS 27.0\"."), "runtimeIdentifier": Schema.string(),
        "deviceType": Schema.nullable("string"),
        "state": Schema.string("simctl state before the command ran: Booted, Shutdown, …"),
    ], required: ["udid", "name", "runtime", "runtimeIdentifier", "deviceType", "state"])

    static let profileSummary = Schema.object([
        "name": Schema.string("\"auto: MyApp.app\", \"full\", or a saved profile name."),
        "appPath": Schema.nullable("string"),
        "keepCount": Schema.integer(), "disableCount": Schema.integer(),
    ], required: ["name", "appPath", "keepCount", "disableCount"])

    static let readOnly: JSONValue = ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
    static let rebooting: JSONValue = ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false]

    static let status = MCPTool(
        name: "status", title: "List simulators",
        description: "List every available simulator: UDID, name, runtime, state, whether it is light (field slim: true; and how many services are off), its light set (profileName), and process count and memory of booted ones. Read-only. Call this first to pick a simulator.",
        inputSchema: Schema.object(["deviceSet": deviceSetArg]),
        outputSchema: Schema.object([
            "schemaVersion": Schema.integer(), "deviceSet": Schema.nullable("string"),
            "simulators": Schema.array(Schema.object([
                "udid": Schema.string(), "name": Schema.string(), "runtime": Schema.string(),
                "runtimeIdentifier": Schema.string(), "deviceType": Schema.nullable("string"),
                "state": Schema.string(), "slim": Schema.boolean(), "disabledCount": Schema.integer(),
                "profileName": Schema.nullable("string"), "processes": Schema.nullable("integer"),
                "memoryBytes": Schema.nullable("integer"),
            ], required: ["udid", "name", "runtime", "runtimeIdentifier", "deviceType", "state", "slim",
                          "disabledCount", "profileName", "processes", "memoryBytes"])),
        ], required: ["schemaVersion", "deviceSet", "simulators"]),
        annotations: readOnly
    ) { args in try await FastIOSCommands.status() }

    static let profile = MCPTool(
        name: "profile", title: "Show an app's light set",
        description: "Read a built simulator app (Info.plist, entitlements, linked frameworks) and return which simulator services it needs and why, and which would be turned off. Changes nothing. `app` may be a .app, a DerivedData folder, Build/Products, or a project folder (newest simulator .app wins).",
        inputSchema: Schema.object([
            "app": Schema.string("Path to the .app or a folder that contains a simulator build."),
            "keep": keepArg,
        ], required: ["app"]),
        outputSchema: Schema.object([
            "schemaVersion": Schema.integer(), "app": Schema.string(), "bundleIdentifier": Schema.nullable("string"),
            "profile": Schema.object([
                "name": Schema.string(), "appPath": Schema.string(),
                "keep": Schema.map(strings), "disable": strings,
            ], required: ["name", "keep", "disable"]),
            "matchedRules": Schema.array(Schema.object([
                "trigger": Schema.string(), "reason": Schema.string(), "keep": strings,
            ], required: ["trigger", "reason", "keep"])),
            "catalogCount": Schema.integer(), "neverDisabled": strings,
        ], required: ["schemaVersion", "app", "bundleIdentifier", "profile", "matchedRules", "catalogCount", "neverDisabled"]),
        annotations: readOnly, positional: ["app"]
    ) { args in try await FastIOSCommands.profile(app: try args.string("app"), keep: args.strings("keep")) }

    static let slim = MCPTool(
        name: "slim", title: "Make a simulator light",
        description: "Turn off the simulator services the app does not need (about 2.8 GB to 0.8 GB). A booted simulator is shut down and rebooted (takes 30 s to 3 min); a stopped one starts light next time, or now with boot=true. Without app: uses the last derived profile, or full=true turns off the whole catalog. Only use on a simulator you created.",
        inputSchema: Schema.object([
            "simulator": simulatorArg,
            "app": Schema.string("Built app or folder to derive the profile from. Remembered for later calls."),
            "keep": keepArg,
            "full": Schema.boolean("Turn off every catalog service when no app is given."),
            "strict": Schema.boolean("Keep only what the app declares (Info.plist, entitlements, extensions), not what its libraries link. Pair with heal, which turns a needed service back on."),
            "boot": Schema.boolean("Start the simulator afterwards if it is stopped."),
            "deviceSet": deviceSetArg,
        ], required: ["simulator"]),
        outputSchema: Schema.object([
            "schemaVersion": Schema.integer(), "simulator": simulatorRef, "profile": profileSummary,
            "disabled": strings, "reenabled": strings, "booted": Schema.boolean(),
            "verified": Schema.boolean("Booted and launchd reports every override."),
            "notHonoured": strings, "log": strings,
        ], required: ["schemaVersion", "simulator", "profile", "disabled", "reenabled", "booted", "verified", "notHonoured", "log"]),
        annotations: rebooting, positional: ["simulator"]
    ) { args in
        try await FastIOSCommands.slim(simulator: try args.string("simulator"), app: args.optionalString("app"),
                                       keep: args.strings("keep"), full: args.bool("full"), boot: args.bool("boot"),
                                       strict: args.bool("strict"))
    }

    static let off = MCPTool(
        name: "off", title: "Make a simulator full again",
        description: "Remove every service override fast-ios manages, so the simulator runs full again (field alreadyStock: it was full already). A booted simulator is rebooted if anything changes. Use when a feature the app needs stops working on a light simulator and keep is not enough.",
        inputSchema: Schema.object([
            "simulator": simulatorArg,
            "boot": Schema.boolean("Boot the simulator afterwards if it is shut down."),
            "deviceSet": deviceSetArg,
        ], required: ["simulator"]),
        outputSchema: Schema.object([
            "schemaVersion": Schema.integer(), "simulator": simulatorRef, "reenabled": strings,
            "alreadyStock": Schema.boolean(), "booted": Schema.boolean(), "log": strings,
        ], required: ["schemaVersion", "simulator", "reenabled", "alreadyStock", "booted", "log"]),
        annotations: rebooting, positional: ["simulator"]
    ) { args in try await FastIOSCommands.off(simulator: try args.string("simulator"), boot: args.bool("boot")) }

    static let measure = MCPTool(
        name: "measure", title: "Measure a booted simulator",
        description: "Count the processes of a booted simulator and sum their memory (the footprint tool's numbers), with every process largest first. Read-only; takes a few seconds.",
        inputSchema: Schema.object(["simulator": simulatorArg, "deviceSet": deviceSetArg], required: ["simulator"]),
        outputSchema: Schema.object([
            "schemaVersion": Schema.integer(), "simulator": simulatorRef,
            "processCount": Schema.integer(), "totalBytes": Schema.integer(),
            "processes": Schema.array(Schema.object([
                "pid": Schema.integer(), "name": Schema.string(), "bytes": Schema.integer(),
            ], required: ["pid", "name", "bytes"])),
        ], required: ["schemaVersion", "simulator", "processCount", "totalBytes", "processes"]),
        annotations: readOnly, positional: ["simulator"]
    ) { args in try await FastIOSCommands.measure(simulator: try args.string("simulator")) }

    static let catalog = MCPTool(
        name: "catalog", title: "List the services fast-ios may turn off",
        description: "Every simulator service fast-ios may turn off, by category, with what stops working while it is off, plus the services it never turns off. Use it to find the label to pass as keep.",
        inputSchema: Schema.object([:]),
        outputSchema: Schema.object([
            "schemaVersion": Schema.integer(), "slimmableCount": Schema.integer(),
            "categories": Schema.array(Schema.object([
                "id": Schema.string(), "name": Schema.string(), "description": Schema.string(),
                "downside": Schema.string(), "approxMemoryMB": Schema.integer(),
                "services": Schema.array(Schema.object(["label": Schema.string(), "description": Schema.string()],
                                                       required: ["label", "description"])),
            ], required: ["id", "name", "description", "downside", "approxMemoryMB", "services"])),
            "neverDisabled": Schema.array(Schema.object(["label": Schema.string(), "reason": Schema.string()],
                                                        required: ["label", "reason"])),
        ], required: ["schemaVersion", "slimmableCount", "categories", "neverDisabled"]),
        annotations: readOnly
    ) { _ in FastIOSCommands.catalog() }
}
