import Foundation

// The `shot` tool: screenshot + accessibility tree of an app screen. Its
// output schema mirrors Shot.Result.

extension MCPTools {
    static let shot = MCPTool(
        name: "shot", title: "Screenshot an app screen with its accessibility tree",
        description: "Read first: the accessibility tree works only for simulators in the default device set (xcodebuild cannot see a custom set, so with deviceSet the result has a screenshot and treeStatus \"unavailable\"). Visual proof of a UI change in one call: uses the given simulator, else a running light one, else starts a stopped iPhone light; installs the app only if the build changed; relaunches it; opens url (and taps Open on iOS's \"Open in …?\" prompt); waits for the screen to settle (default at most 6 s; a spinner or other animation in under 1% of the screen is ignored, see screenStability) or for wait text; returns the PNG path, the accessibility tree as text (type, label, id, value, frame in points) and step timings. The tree takes 10 to 25 s (XCTest via xcodebuild); noTree=true skips it.",
        inputSchema: Schema.object([
            "app": Schema.string("Built simulator .app, or a folder to find the newest one in (DerivedData, Build/Products, project)."),
            "udid": Schema.string("Simulator to use: a UDID, a unique name, or \"booted\". Booted if shut down. Omit to pick one."),
            "url": Schema.string("Deep link to open after launch, such as myapp://settings."),
            "wait": Schema.string("Seconds to wait for the screen to settle (default 6), or a text to wait for in a label or identifier (default 20 s)."),
            "timeout": Schema.integer("Overrides the wait timeout, in seconds."),
            "out": Schema.string("Folder for the PNG. Default: $TMPDIR/fast-ios-shots."),
            "noTree": Schema.boolean("Skip the accessibility tree."),
            "noSession": Schema.boolean("Do not keep the tree runner alive after this shot (each tree then costs 10 to 25 s)."),
            "maxWidth": Schema.integer("Shrink the PNG to at most this many pixels wide, such as 400."),
            "scale": Schema.number("Shrink the PNG by this factor, between 0 and 1, such as 0.33."),
            "grant": grantArg,
            "deviceSet": deviceSetArg,
        ].merging(cacheArgs) { a, _ in a }, required: ["app"]),
        outputSchema: Schema.object([
            "schemaVersion": Schema.integer(),
            "simulator": simulatorRef,
            "simulatorSource": Schema.string("given, booted-slim or booted-now."),
            "bundleId": Schema.string(), "appPath": Schema.string(),
            "installed": Schema.boolean("False when the same build was already installed."),
            "url": Schema.nullable("string"),
            "openPromptAccepted": Schema.nullable("boolean", "Whether an \"Open in …?\" prompt appeared and was tapped."),
            "urlNote": Schema.nullable("string"),
            "screenshot": Schema.string("PNG path."),
            "screenshotBytes": Schema.integer(), "screenshotWidth": Schema.integer(), "screenshotHeight": Schema.integer(),
            "pixelsPerPoint": Schema.nullable("number", "Multiply a tree frame by this to find it in the PNG."),
            "treeSession": Schema.nullable("string", "started (this shot paid for the runner start), reused (fast), off, or null without a tree."),
            "granted": Schema.array(Schema.string(), "Permissions granted before launch with simctl privacy."),
            "screenStable": Schema.boolean("The screen settled before the timeout (see screenStability)."),
            "screenStability": Schema.string("identical, small-animation (under 1% of the screen kept moving, ignored) or still-changing (timeout)."),
            "changedPercent": Schema.nullable("number", "Largest share of the screen that changed between the last screenshots."),
            "waitText": Schema.nullable("string"),
            "waitTextFound": Schema.nullable("boolean"),
            "treeStatus": Schema.string("ok, skipped, unavailable or failed."),
            "treeNote": Schema.nullable("string", "Why the tree is missing, or how it was read."),
            "tree": Schema.nullable("string", "One element per line: Type \"label\" id=… value=\"…\" [x,y,w,h]."),
            "treeElements": Schema.nullable("integer"),
            "appCache": appCacheSchema,
            "timings": Schema.array(Schema.object(["step": Schema.string(), "ms": Schema.integer()],
                                                  required: ["step", "ms"])),
            "totalMs": Schema.integer(),
            "log": strings,
        ], required: ["schemaVersion", "simulator", "simulatorSource", "bundleId", "appPath", "installed", "url",
                      "openPromptAccepted", "urlNote", "screenshot", "screenshotBytes", "screenshotWidth",
                      "screenshotHeight", "pixelsPerPoint", "treeSession", "granted", "screenStable", "screenStability", "changedPercent",
                      "waitText", "waitTextFound",
                      "treeStatus", "treeNote", "tree", "treeElements", "timings", "totalMs", "log"]),
        annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false]
    ) { args in
        var options = Shot.Options(
            appPath: try args.string("app"),
            outDir: args.optionalString("out").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? Shot.Options.defaultOutDir)
        options.udid = args.optionalString("udid")
        options.url = args.optionalString("url")
        options.tree = !args.bool("noTree")
        options.session = !args.bool("noSession")
        if case .int(let w)? = args.raw["maxWidth"] {
            guard w > 0 else { throw InvalidArguments("maxWidth must be a positive number of pixels.") }
            options.maxWidth = Int(w)
        }
        if let s = args.number("scale") {
            guard s > 0, s <= 1 else { throw InvalidArguments("scale must be more than 0 and at most 1.") }
            options.scale = s
        }
        options.grant = try Privacy.validate(args.strings("grant"))
        options.cache = try cacheRequest(args)
        if let wait = args.optionalString("wait") { options.setWait(wait) }
        if case .int(let seconds)? = args.raw["timeout"] {
            guard seconds >= 0 else { throw InvalidArguments("timeout must be 0 or more seconds.") }
            options.timeout = .seconds(seconds)
        }
        return try await Shot.run(options)
    }
}
