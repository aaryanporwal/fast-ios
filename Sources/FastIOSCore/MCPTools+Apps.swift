import Foundation

// The app cache: reuse a built simulator .app when the project's native
// inputs have not changed. `apps` lists, explains and clears it; `run` and
// `shot` use it for a project folder (see AppCache.resolve).

extension MCPTools {
    /// Arguments `run` and `shot` add for the app cache.
    static let cacheArgs: [String: JSONValue] = [
        "build": Schema.string("Shell command that builds the simulator app, run in the project folder when no stored app matches. The result is stored, and agents that miss on the same fingerprint at the same time wait for this one build."),
        "builtApp": Schema.string("Where the build writes the .app, relative to the project folder. Default: the newest simulator build in the project."),
        "configuration": Schema.string("Build configuration of the app, part of the fingerprint. Default Debug."),
        "variant": Schema.string("Free text added to the fingerprint, for builds that differ in a way the files do not show (a scheme, a setting on the build command line)."),
        "buildTimeout": Schema.string("How long to wait for another agent's build of the same app, such as \"20m\" (the default)."),
    ]

    static let appCacheSchema = Schema.nullable("object", "Whether the app came from the app cache: status hit, built, waited or miss; fingerprint; kind (expo or files); builtAt; savedSeconds; message. null when the cache was not used.")

    static func cacheRequest(_ args: ToolArguments) throws -> AppCacheRequest {
        var c = AppCacheRequest()
        c.build = args.optionalString("build")
        c.builtApp = args.optionalString("builtApp")
        if let conf = args.optionalString("configuration") {
            guard !conf.isEmpty else { throw InvalidArguments("configuration must not be empty, such as Debug.") }
            c.options.configuration = conf
        }
        c.options.variant = args.optionalString("variant")
        if let t = args.optionalString("buildTimeout") {
            guard let v = FastIOSCommands.parseDuration(t) else { throw InvalidArguments("buildTimeout must look like 90s, 20m or 1h; got \(t).") }
            c.timeout = v
        }
        return c
    }

    static let cachedAppSchema = Schema.object([
        "fingerprint": Schema.string(), "kind": Schema.string("expo (native inputs only) or files (every file)."),
        "projectID": Schema.string(), "projectName": Schema.string(), "configuration": Schema.string(),
        "variant": Schema.nullable("string"), "bundleIdentifier": Schema.string(), "appName": Schema.string(),
        "app": Schema.string("Path of the stored .app."),
        "architectures": strings, "xcodeVersion": Schema.string(), "builtAt": Schema.string(),
        "storedAt": Schema.string(), "lastUsedAt": Schema.string(), "sizeBytes": Schema.integer(),
        "buildSeconds": Schema.nullable("number"),
    ], required: ["fingerprint", "kind", "projectID", "configuration", "bundleIdentifier", "app", "builtAt", "sizeBytes"])

    static let apps = MCPTool(
        name: "apps", title: "Stored simulator apps (app cache)",
        description: "The app cache: built simulator apps keyed by a fingerprint of the project's inputs, so an agent whose native code is unchanged skips the compile. action list (default): every stored app. why: compare the project's current fingerprint with its stored apps and name the inputs that differ. add: store a built .app (target) for a project folder (project). clear: remove one stored app (target = fingerprint) or all. Expo projects with @expo/fingerprint are keyed by native inputs only (a JavaScript change still hits, Debug builds); other projects by every file, so only identical sources hit.",
        inputSchema: Schema.object([
            "action": Schema.string("list, why, add or clear. Default list."),
            "target": Schema.string("why: the project folder (default: the current folder). add: the built .app. clear: a fingerprint or its first characters; omit to clear all."),
            "project": Schema.string("add: the project folder the app was built from (default: the current folder)."),
            "configuration": Schema.string("why and add: build configuration. Default: from the app's folder name (Debug-iphonesimulator), else Debug for why."),
            "variant": Schema.string("why and add: the same variant text as run --variant."),
            "buildSeconds": Schema.number("add: how long the build took, so a later hit can say how much it saved."),
        ]),
        outputSchema: Schema.object([
            "schemaVersion": Schema.integer(), "action": Schema.string(), "folder": Schema.string("The cache folder."),
            "apps": Schema.array(cachedAppSchema, "list: stored apps, most recently used first. add: the stored app. clear: what was removed."),
            "totalBytes": Schema.integer(), "maxBytes": Schema.integer(),
            "why": Schema.nullable("object", "why: fingerprint, kind, hit (bool), comparedWith (fingerprint or null), changed/added/removed input names, message."),
            "message": Schema.string(),
        ], required: ["schemaVersion", "action", "folder", "apps", "totalBytes", "maxBytes", "why", "message"]),
        annotations: ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false],
        positional: ["action", "target"]
    ) { args in
        let action = args.optionalString("action") ?? "list"
        var variant: String? { args.optionalString("variant") }
        switch action {
        case "list":
            let all = AppCache.list()
            return AppsOutput(action: action, apps: all,
                              message: all.isEmpty ? "No stored apps. Store one with `fast-ios apps add <app> --project <folder>`, or run with --build." : "\(all.count) stored app\(all.count == 1 ? "" : "s").")
        case "why":
            let folder = args.optionalString("target") ?? FileManager.default.currentDirectoryPath
            var o = FingerprintOptions()
            o.configuration = args.optionalString("configuration") ?? "Debug"
            o.variant = variant
            let why = try await AppsWhy.explain(project: folder, options: o)
            return AppsOutput(action: action, apps: [], why: why, message: why.message)
        case "add":
            guard let target = args.optionalString("target") else {
                throw InvalidArguments("`fast-ios apps add` needs the built .app: `fast-ios apps add <app> --project <folder>`. Nothing was stored.")
            }
            let app = try AppInspector.locateApp(target)
            let project = args.optionalString("project") ?? FileManager.default.currentDirectoryPath
            var o = FingerprintOptions()
            guard let conf = args.optionalString("configuration") ?? AppCache.configuration(fromPath: app.path) else {
                throw InvalidArguments("fast-ios cannot tell the configuration of \(app.lastPathComponent) from its folder. Pass --configuration Debug (or the one it was built with). Nothing was stored.")
            }
            o.configuration = conf
            o.variant = variant
            let fp = try await Fingerprinter.compute(project, options: o)
            let name = URL(fileURLWithPath: (project as NSString).expandingTildeInPath).standardizedFileURL.lastPathComponent
            let stored = try await AppCache.add(app, fingerprint: fp, projectName: name, variant: variant, buildSeconds: args.number("buildSeconds"))
            let what = fp.kind == .expo ? "native code" : "source files"
            return AppsOutput(action: action, apps: [stored],
                              message: "Stored \(stored.appName) as \(fp.short). `fast-ios run` in any worktree of this project with the same \(what) now reuses it.")
        case "clear":
            let removed = try AppCache.clear(args.optionalString("target"))
            return AppsOutput(action: action, apps: removed,
                              message: removed.isEmpty ? "Nothing was stored." : "Removed \(removed.count) stored app\(removed.count == 1 ? "" : "s").")
        default:
            throw InvalidArguments("apps takes list, why, add or clear; got \(action). Nothing was changed. See `fast-ios apps --help`.")
        }
    }
}

/// `apps --json` output.
public struct AppsOutput: Encodable, Sendable {
    public struct Entry: Encodable, Sendable {
        public let fingerprint: String, kind: String, projectID: String, projectName: String, configuration: String
        @EncodeNull public var variant: String?
        public let bundleIdentifier: String, appName: String, app: String, architectures: [String], xcodeVersion: String
        /// ISO 8601.
        public let builtAt: String, storedAt: String, lastUsedAt: String
        public let sizeBytes: Int64
        @EncodeNull public var buildSeconds: Double?
    }
    public var schemaVersion = JSONOutput.schemaVersion
    public let action: String
    public let folder = AppCache.folder.path
    public let apps: [Entry]
    public let totalBytes: Int64
    public let maxBytes = AppCache.maxBytes
    @EncodeNull public var why: AppsWhy.Result?
    public let message: String

    init(action: String, apps: [CachedApp], why: AppsWhy.Result? = nil, message: String) {
        self.action = action
        self.apps = apps.map {
            Entry(fingerprint: $0.fingerprint, kind: $0.kind.rawValue, projectID: $0.projectID, projectName: $0.projectName,
                  configuration: $0.configuration, variant: $0.variant, bundleIdentifier: $0.bundleIdentifier, appName: $0.appName,
                  app: AppCache.appURL($0).path, architectures: $0.architectures, xcodeVersion: $0.xcodeVersion,
                  builtAt: AppCache.iso($0.builtAt), storedAt: AppCache.iso($0.storedAt), lastUsedAt: AppCache.iso($0.lastUsedAt), sizeBytes: $0.sizeBytes, buildSeconds: $0.buildSeconds)
        }
        self.totalBytes = AppCache.list().reduce(0) { $0 + $1.sizeBytes }
        self.why = why
        self.message = message
    }
}

/// `fast-ios apps why <project>`: why the project hits or misses.
public enum AppsWhy {
    public struct Result: Encodable, Sendable {
        public let fingerprint: String
        public let kind: String
        public let hit: Bool
        /// The stored app compared with: the same project, the same
        /// configuration, most recently used. null when none is stored.
        @EncodeNull public var comparedWith: String?
        public let changed: [String]
        public let added: [String]
        public let removed: [String]
        public let message: String
    }

    public static func explain(project folder: String, options: FingerprintOptions) async throws -> Result {
        let fp = try await Fingerprinter.compute(folder, options: options)
        let what = fp.kind == .expo ? "native inputs (@expo/fingerprint)" : "every file in the repository"
        if let hit = AppCache.list().first(where: { $0.fingerprint == fp.hash }) {
            return Result(fingerprint: fp.hash, kind: fp.kind.rawValue, hit: true, comparedWith: hit.fingerprint, changed: [], added: [], removed: [],
                          message: "Hit: \(fp.short) matches \(hit.appName), built \(AppCache.ago(hit.builtAt)). `fast-ios run` here reuses it. Keyed by \(what).")
        }
        let same = AppCache.list().filter { $0.projectID == fp.projectID }
        guard let other = same.first(where: { $0.configuration == fp.configuration }) ?? same.first else {
            return Result(fingerprint: fp.hash, kind: fp.kind.rawValue, hit: false, comparedWith: nil, changed: [], added: [], removed: [],
                          message: "Miss: nothing is stored for this project yet (fingerprint \(fp.short), keyed by \(what)). Store a build with `fast-ios apps add <app> --project \(folder)`, or run with --build.")
        }
        let d = FingerprintDiff(from: other.inputs, to: fp.inputs)
        let names = (d.changed + d.added + d.removed)
        let list = names.prefix(8).map(Self.plain).joined(separator: ", ") + (names.count > 8 ? ", and \(names.count - 8) more" : "")
        return Result(fingerprint: fp.hash, kind: fp.kind.rawValue, hit: false, comparedWith: other.fingerprint,
                      changed: d.changed, added: d.added, removed: d.removed,
                      message: "Miss: \(fp.short) differs from the stored \(other.appName) (\(other.fingerprint.prefix(12)), built \(AppCache.ago(other.builtAt))) in \(names.count) input\(names.count == 1 ? "" : "s"): \(list).")
    }

    /// "file:ios/Podfile.lock" -> "ios/Podfile.lock"; "xcode" -> "Xcode version".
    static func plain(_ input: String) -> String {
        switch input {
        case "xcode": return "Xcode version"
        case "configuration": return "configuration"
        case "arch": return "Mac architecture"
        case "variant": return "variant"
        case "kind": return "fingerprint kind"
        case "schema": return "fast-ios fingerprint rules"
        case "expo:hash": return "the whole Expo fingerprint"
        default:
            for prefix in ["file:", "expo:", "env:"] where input.hasPrefix(prefix) { return String(input.dropFirst(prefix.count)) }
            return input
        }
    }
}
