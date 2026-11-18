import FastIOSCore
import Foundation

/// `--build`, `--built-app`, `--configuration`, `--variant`, `--build-timeout`
/// of `run` and `shot`.
func cacheRequest(value: (String) -> String?) throws -> AppCacheRequest {
    var c = AppCacheRequest()
    c.build = value("--build")
    c.builtApp = value("--built-app")
    if let conf = value("--configuration") { c.options.configuration = conf }
    c.options.variant = value("--variant")
    if let t = value("--build-timeout") {
        guard let v = FastIOSCommands.parseDuration(t) else { throw UsageError("--build-timeout needs a duration such as 90s, 20m or 1h; got \(t).") }
        c.timeout = v
    }
    return c
}

/// `fast-ios bench --scenario build --project <folder> --build "<command>"`
func runBuildBench(_ f: Flags) async throws {
    guard let project = f.value("--project"), let build = f.value("--build") else {
        throw UsageError("--scenario build needs --project <folder> and --build \"<command that compiles the app>\". Nothing was run.")
    }
    var o = BuildBenchOptions(project: project, build: build)
    o.builtApp = f.value("--built-app")
    if let c = f.value("--configuration") { o.configuration = c }
    if let r = f.value("--repeat") {
        guard let n = Int(r), n > 0 else { throw UsageError("--repeat needs a positive number, e.g. --repeat 3.") }
        o.repeats = n
    }
    let r = try await BuildBench.run(o, log: stderrLog)
    if jsonMode { print(try JSONOutput.encode(r, pretty: true)); return }
    let keyed = r.kind == "expo" ? "native inputs (@expo/fingerprint)" : "every file (\(r.inputs) inputs)"
    print("App cache bench: \(r.project), keyed by \(keyed). Xcode \(r.xcode), \(r.mac).")
    print("  Compile with --build (a miss):            \(Bench.fmt(r.compileSeconds)) s")
    print("  App cache hit (fingerprint + lookup):      \(String(format: "%.2f", r.hitMedian)) s, median of \(r.hitSeconds.count)")
    print("  Fingerprint alone:                         \(String(format: "%.2f", r.fingerprintMedian)) s, median of \(r.fingerprintSeconds.count)")
    print("  Saved by each hit:                         \(Bench.fmt(r.savedSeconds)) s")
    for n in r.notes { print(Style.dim("  " + n)) }
}

/// `fast-ios apps [why <project> | add <app> --project <folder> | clear [<fingerprint>]]`
func runAppsCommand(_ words: [String]) async throws {
    let f = Flags(words: words)
    try f.check(against: "apps")
    let result = try await MCPTools.named("apps")!.callFromCLI(words)
    let action = result["action"]?.string ?? "list"
    let apps = result["apps"]?.array ?? []
    func size(_ v: JSONValue?) -> String {
        let bytes: Int64 = if case .int(let n)? = v { n } else { 0 }
        return bytes >= 1_073_741_824 ? String(format: "%.1f GB", Double(bytes) / 1_073_741_824) : "\(bytes / 1_048_576) MB"
    }
    func date(_ v: JSONValue?) -> Date? { v?.string.flatMap { ISO8601DateFormatter().date(from: $0) } }
    switch action {
    case "list":
        if apps.isEmpty {
            print(result["message"]?.string ?? "")
            return
        }
        print("Stored apps (\(size(result["totalBytes"])) of \(size(result["maxBytes"])), most recently used first):")
        for a in apps {
            let built = date(a["builtAt"]).map { AppCache.ago($0) } ?? "?"
            let used = date(a["lastUsedAt"]).map { AppCache.ago($0) } ?? "?"
            let kind = a["kind"]?.string == "expo" ? "native code" : "every file"
            print("  \(Style.bold(String((a["fingerprint"]?.string ?? "").prefix(12))))  \(a["appName"]?.string ?? "")  \(a["configuration"]?.string ?? "")  \(size(a["sizeBytes"]))")
            print(Style.dim("      \(a["projectName"]?.string ?? "") · keyed by \(kind) · built \(built) · used \(used)"))
        }
        print(Style.dim("Why a project misses: `fast-ios apps why <project>`. Remove: `fast-ios apps clear [<fingerprint>]`."))
    case "why":
        print(result["message"]?.string ?? "")
        if verboseMode, let why = result["why"] {
            for key in ["changed", "added", "removed"] {
                for name in why[key]?.array?.compactMap(\.string) ?? [] { print("  \(key): \(name)") }
            }
        } else if let n = result["why"]?["changed"]?.array?.count, n > 8 {
            print(Style.dim("Every input: add --verbose."))
        }
    default:
        print(result["message"]?.string ?? "")
    }
}
