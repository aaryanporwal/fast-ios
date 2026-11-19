import Foundation

/// `fast-ios run`: lease a simulator, slim it for the app, install, launch.
public struct RunOutput: Encodable, Sendable {
    public var schemaVersion = JSONOutput.schemaVersion
    public let udid: String
    public let name: String
    /// The .app that was installed.
    public let app: String
    /// How the app was chosen: "--app", or why it was picked automatically.
    public let appSource: String
    @EncodeNull public var bundleIdentifier: String?
    public let profile: ProfileSummary
    /// "leased" (from the fast-ios pool) or "given" (--simulator).
    public let simulatorSource: String
    /// When the lease ends unless released earlier (null for --simulator).
    @EncodeNull public var leaseExpiresAt: String?
    public let launched: Bool
    /// True when the leased simulator was cloned from a slim template.
    public var cloned = false
    /// Simulators that failed to boot and were retired before this one.
    public var replaced: [Replacement] = []
    @EncodeNull public var pid: Int?
    @EncodeNull public var url: String?
    /// Whether the app came from the app cache; null when the cache was not used.
    @EncodeNull public var appCache: AppCacheSummary? = nil
    /// Permissions granted before launch with simctl privacy.
    public let granted: [String]
    public let seconds: RunTimings
    public let log: [String]
}

public struct RunTimings: Encodable, Sendable {
    /// Part of `simulator` spent waiting for memory or the lease queue.
    public let waited: Double
    /// Getting a slim, booted simulator, waiting included.
    public let simulator: Double
    public let install: Double
    public let launch: Double
    public let total: Double
}

public struct RunRequest: Sendable {
    public var app: String?
    /// Folder to search for a build when `app` is nil.
    public var folder: String = FileManager.default.currentDirectoryPath
    public var url: String?
    public var keep: [String] = []
    /// simctl privacy services to grant before launch (Privacy.validate).
    public var grant: [String] = []
    public var runtime: String?
    public var deviceType: String?
    public var ttl: TimeInterval = 30 * 60
    /// Use this simulator instead of leasing one. It must be one you created.
    public var simulator: String?
    public var launch = true
    /// Retire a leased simulator that refuses the launch and try once more.
    public var retryOnBadSimulator = true
    /// When a new boot may start; see AdmissionPolicy.
    public var policy = AdmissionPolicy()
    /// How long to wait while the Mac is short of memory. 0: refuse at once.
    public var memoryWait: TimeInterval = 0
    /// The app cache, for a project folder: --build, --configuration, --variant.
    public var cache = AppCacheRequest()
    public init() {}
}

extension Optional {
    func asyncMap<U>(_ f: (Wrapped) async throws -> U) async rethrows -> U? {
        guard let v = self else { return nil }
        return try await f(v)
    }
}

public enum AppRunner {
    public static func run(_ r: RunRequest, log: @escaping Log = { _ in }) async throws -> RunOutput {
        let collected = LogCollector()
        let both: Log = { collected.append($0); log($0) }
        let start = ContinuousClock.now
        try KeepNames.validate(r.keep)

        // A project folder (the current one, or --app <folder>) may use the app cache.
        let project = r.app.map { AppCache.isProjectFolder($0) ? $0 : nil } ?? r.folder
        let cached = try await project.asyncMap { try await AppCache.resolve(project: $0, r.cache, log: both) } ?? nil
        let appURL: URL, appSource: String
        if let app = cached?.app, let source = cached?.source {
            (appURL, appSource) = (app, source)
        } else {
            (appURL, appSource) = try r.app.map { (try AppInspector.locateApp($0), "--app") } ?? findBuild(in: r.folder)
            if r.app == nil || project != nil { both("Using \(appURL.path) (\(appSource)).") }
        }
        let facts = try await AppInspector.inspect(appURL)
        let profile = Profiler.derive(from: facts, keeping: r.keep).profile

        let udid: String, name: String, simulatorSource: String
        var expires: String?
        var waited = 0.0
        var cloned = false
        var replaced: [Replacement] = []
        if let selector = r.simulator {
            let device = try await Simctl.resolve(selector)
            both("Making \(device.name) light for \(facts.appName)…")
            _ = try await Slimmer.slim(device, profile: profile, boot: true, log: both)
            (udid, name, simulatorSource) = (device.udid, device.name, "given")
        } else {
            var req = LeaseRequest(profile: profile)
            req.runtime = r.runtime; req.deviceType = r.deviceType; req.ttl = r.ttl
            req.policy = r.policy; req.memoryWait = r.memoryWait
            let lease = try await LeaseManager.lease(req, log: both)
            (udid, name, simulatorSource) = (lease.udid, lease.name, "leased")
            waited = lease.waitedSeconds
            cloned = lease.cloned
            replaced = lease.replaced
            expires = ISO8601DateFormatter().string(from: lease.expiresAt)
        }
        let tSim = ContinuousClock.now

        both("Installing \(facts.appName) on \(name)…")
        try await Simctl.simctl("install", udid, appURL.path)
        if !r.grant.isEmpty, let bundle = facts.bundleIdentifier {
            both("Granting \(r.grant.joined(separator: ", ")) to \(bundle)…")
            try await Privacy.grant(r.grant, bundleID: bundle, udid: udid)
        }
        let tInstall = ContinuousClock.now

        var pid: Int?
        var launched = false
        if r.launch, let bundle = facts.bundleIdentifier {
            // `simctl launch` prints "<bundle id>: <pid>".
            let out: String
            do {
                out = try await Simctl.simctl("launch", udid, bundle).text
            } catch let e as ShellError where simulatorSource == "leased" && r.retryOnBadSimulator {
                // A leased simulator whose launchd refuses the launch is broken:
                // retire it and run once more on another one.
                let failure = BootFailureContext(udid: udid, adopted: LeaseManager.isAdopted(udid),
                                                 failure: .notResponding(e.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
                let gone = await LeaseManager.retire(failure, log: both)
                var again = r
                again.retryOnBadSimulator = false
                var second = try await run(again, log: log)
                second.replaced = replaced + [gone] + second.replaced
                return second
            }
            pid = out.split(separator: ":").last.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            launched = true
        } else if r.launch {
            both("The app has no CFBundleIdentifier; installed but not launched.")
        }
        if let url = r.url {
            try await Simctl.simctl("openurl", udid, url)
        }
        let end = ContinuousClock.now
        func s(_ d: Duration) -> Double { ((Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 10).rounded() / 10 }
        var output = RunOutput(
            udid: udid, name: name, app: appURL.path, appSource: appSource, bundleIdentifier: facts.bundleIdentifier,
            profile: ProfileSummary(profile), simulatorSource: simulatorSource, leaseExpiresAt: expires,
            launched: launched, pid: pid, url: r.url,
            granted: facts.bundleIdentifier == nil ? [] : Privacy.expand(r.grant),
            seconds: RunTimings(waited: waited, simulator: s(tSim - start), install: s(tInstall - tSim), launch: s(end - tInstall), total: s(end - start)),
            log: collected.lines)
        output.cloned = cloned
        output.replaced = replaced
        output.appCache = cached?.summary
        return output
    }

    /// The newest simulator build for the project in `folder`: an Expo or
    /// custom build folder inside it, or the Xcode DerivedData folder whose
    /// workspace lives in it. Returns the app and why it was picked.
    public static func findBuild(in folder: String) throws -> (URL, String) {
        let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL
        if root.pathExtension == "app" { return (root, "the folder is an app") }
        var candidates: [(URL, String)] = []
        for sub in ["ios/build", "build", "DerivedData", "ios/DerivedData"] {
            let dir = root.appendingPathComponent(sub)
            if FileManager.default.fileExists(atPath: dir.path), let app = try? AppInspector.locateApp(dir.path) {
                candidates.append((app, "newest simulator build in \(sub)/"))
            }
        }
        let derived = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        for entry in (try? FileManager.default.contentsOfDirectory(at: derived, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("info.plist")),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let workspace = plist["WorkspacePath"] as? String,
                  workspace.hasPrefix(root.path + "/") else { continue }
            let products = entry.appendingPathComponent("Build/Products")
            if let app = try? AppInspector.locateApp(products.path) {
                candidates.append((app, "newest simulator build in DerivedData for \(URL(fileURLWithPath: workspace).lastPathComponent)"))
            }
        }
        func date(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        guard let best = candidates.max(by: { date($0.0) < date($1.0) }) else {
            throw InspectError(message: """
                No simulator build found for \(root.path). Build the app for the simulator first \
                (Xcode: Product > Build with an iOS Simulator destination; `xcodebuild -scheme <scheme> \
                -destination 'generic/platform=iOS Simulator' build`; Expo: `npx expo run:ios`), \
                run fast-ios from the project folder, or pass --app <path to .app>.
                """)
        }
        return best
    }
}
