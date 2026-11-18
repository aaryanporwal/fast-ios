import Foundation

/// `fast-ios shot`: one call that installs, launches and photographs an app
/// screen, with its accessibility tree, for an agent that changed the UI.
public enum Shot {
    public struct Options: Sendable {
        public var appPath: String
        public var udid: String?
        public var url: String?
        /// Wait for this text (label or identifier) before the screenshot.
        public var waitText: String?
        /// How long to wait for a stable screen (default 6 s; a screen with
        /// only a small animation settles in about 1 s) or for `waitText`.
        public var timeout: Duration = .seconds(6)
        public var outDir: URL
        public var tree = true
        /// Keep the XCTest runner alive for the next shot (see ShotSession).
        public var session = true
        /// Shrink the PNG to at most this many pixels wide.
        public var maxWidth: Int?
        /// Shrink the PNG by this factor (0 < scale ≤ 1).
        public var scale: Double?
        /// simctl privacy services to grant before launch (Privacy.validate).
        public var grant: [String] = []
        /// The app cache, when appPath is a project folder.
        public var cache = AppCacheRequest()

        public init(appPath: String, outDir: URL) {
            self.appPath = appPath
            self.outDir = outDir
        }

        /// The default folder for screenshots: `$TMPDIR/fast-ios-shots`.
        public static var defaultOutDir: URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("fast-ios-shots", isDirectory: true)
        }

        /// `--wait`: a number is the timeout for a stable screen; anything
        /// else is text to wait for, with a 20 s timeout.
        public mutating func setWait(_ wait: String) {
            if let seconds = Double(wait), seconds >= 0 {
                timeout = .milliseconds(Int(seconds * 1000))
            } else {
                waitText = wait
                timeout = .seconds(20)
            }
        }
    }

    public struct Timing: Sendable, Encodable {
        public let step: String
        public let ms: Int
    }

    /// What `shot --json` prints and the MCP `shot` tool returns. Optional
    /// fields are always present, as null when they do not apply.
    public struct Result: Sendable, Encodable {
        public var schemaVersion = JSONOutput.schemaVersion
        /// The simulator used; `state` is its state when the shot was taken.
        @EncodeNull public var simulator: SimulatorRef?
        /// "given", "booted-slim" (already running slim) or "booted-now".
        public var simulatorSource = ""
        public var bundleId = ""
        public var appPath = ""
        /// Whether this call installed the app (false: the same build was installed).
        public var installed = false
        @EncodeNull public var url: String?
        /// With url and the tree runner: whether an "Open in …?" prompt
        /// appeared and was accepted. null when the runner did not look.
        @EncodeNull public var openPromptAccepted: Bool?
        @EncodeNull public var urlNote: String?
        public var screenshot = ""
        /// Size of the PNG as written, after any --max-width or --scale.
        public var screenshotBytes = 0
        public var screenshotWidth = 0
        public var screenshotHeight = 0
        /// Screenshot pixels per tree point (multiply a tree frame by this to
        /// find it in the PNG); null without a tree.
        @EncodeNull public var pixelsPerPoint: Double?
        /// "started" (this shot started the runner session), "reused" (it was
        /// running: fast), "off" (--no-session) or null (no tree).
        @EncodeNull public var treeSession: String?
        /// Permissions granted before launch.
        public var granted: [String] = []
        /// The screen settled before the timeout: three screenshots in a row
        /// identical, or differing only in a small area (see screenStability).
        public var screenStable = false
        /// "identical", "small-animation" (a spinner or similar kept moving
        /// in under 1% of the screen, ignored) or "still-changing" (timeout).
        public var screenStability = "still-changing"
        /// Largest share of the screen that changed between the last
        /// screenshots, in percent; null when the screen never settled.
        @EncodeNull public var changedPercent: Double?

        mutating func apply(_ s: Stability) {
            screenStable = s.stable
            screenStability = s.kind
            changedPercent = s.changedPercent.map { ($0 * 100).rounded() / 100 }
        }
        @EncodeNull public var waitText: String?
        /// null when there was no wait text or no tree to search.
        @EncodeNull public var waitTextFound: Bool?
        /// "ok", "skipped" (no tree asked), "unavailable" or "failed".
        public var treeStatus = "skipped"
        /// Why the tree is missing, or how it was read.
        @EncodeNull public var treeNote: String?
        /// One element per line: `Type "label" id=… value="…" [x,y,w,h]`, in points.
        @EncodeNull public var tree: String?
        @EncodeNull public var treeElements: Int?
        /// Whether the app came from the app cache; null when it was not used.
        @EncodeNull public var appCache: AppCacheSummary?
        public var timings: [Timing] = []
        public var totalMs = 0
        /// Progress lines, in order.
        public var log: [String] = []
    }

    public static func run(_ options: Options) async throws -> Result {
        let collector = LogCollector()
        var result = try await run(options, log: collector.append)
        result.log = collector.lines
        return result
    }

    public static func run(_ options: Options, log: Log) async throws -> Result {
        let clock = ContinuousClock()
        let start = clock.now
        var result = Result()
        @discardableResult
        func timed<T>(_ step: String, _ body: () async throws -> T) async rethrows -> T {
            let t0 = clock.now
            defer { result.timings.append(Timing(step: step, ms: ms(clock.now - t0))) }
            return try await body()
        }
        func timedSync<T>(_ step: String, _ body: () throws -> T) rethrows -> T {
            let t0 = clock.now
            defer { result.timings.append(Timing(step: step, ms: ms(clock.now - t0))) }
            return try body()
        }

        // A project folder may use the app cache (same rules as `run`).
        var appPath = options.appPath
        if AppCache.isProjectFolder(appPath) {
            let res = try await withoutActuallyEscaping(log) { l in
                try await timed("app cache") { try await AppCache.resolve(project: appPath, options.cache, log: l) }
            }
            if let cached = res?.app { appPath = cached.path }
            result.appCache = res?.summary
        }
        let app = try AppInspector.locateApp(appPath)
        guard let bundleID = bundleIdentifier(app) else {
            throw ShotError(message: "\(app.path) has no CFBundleIdentifier in its Info.plist.")
        }
        result.appPath = app.path
        result.bundleId = bundleID
        result.url = options.url
        result.waitText = options.waitText

        let (device, source) = try await timed("simulator") { try await pickSimulator(options.udid, app: app, log: log) }
        result.simulator = SimulatorRef(device)
        result.simulatorSource = source

        result.installed = try await timed("install") {
            if try await installedMatches(app, bundleID: bundleID, udid: device.udid) { return false }
            log("Installing \(app.lastPathComponent)…")
            try await Simctl.simctl("install", device.udid, app.path)
            return true
        }
        if !options.grant.isEmpty {
            try await timed("grant") {
                try await Privacy.grant(options.grant, bundleID: bundleID, udid: device.udid)
            }
            result.granted = Privacy.expand(options.grant)
        }
        try await timed("launch") {
            try await Simctl.simctl("launch", "--terminate-running-process", device.udid, bundleID)
        }
        if let url = options.url {
            try await timed("openurl") { try await Simctl.simctl("openurl", device.udid, url) }
        }

        // The tree needs xcodebuild, which only sees the default device set.
        var xctestrun: URL?
        if !options.tree {
            result.treeStatus = "skipped"
        } else if let set = Simctl.deviceSet {
            result.treeStatus = "unavailable"
            result.treeNote = "No tree: the simulator is in the custom device set \(set), and xcodebuild (which runs the XCTest accessibility runner) only sees the default set."
        } else {
            do {
                let prepared = try await timed("treeRunnerPrepare") { try await ShotRunner.prepare(log: log) }
                xctestrun = prepared.xctestrun
            } catch {
                result.treeStatus = "failed"
                result.treeNote = error.localizedDescription
            }
        }

        try FileManager.default.createDirectory(at: options.outDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime, .withTimeZone])
            .replacingOccurrences(of: ":", with: "")
        let png = options.outDir.appendingPathComponent("\(bundleID)-\(stamp).png")
        result.screenshot = png.path

        var rootWidth: Double?
        func readTree(waitText: String?, acceptOpenPrompt: Bool) async {
            guard let xctestrun else { return }
            do {
                let out: ShotRunner.Output
                if options.session {
                    let started = try await timed("treeSession") {
                        try await ShotSession.ensure(udid: device.udid, xctestrun: xctestrun, log: log)
                    }
                    result.treeSession = started ? "started" : "reused"
                    out = try await timed("tree") {
                        try await ShotSession.read(udid: device.udid, bundleID: bundleID, waitText: waitText,
                                                   acceptOpenPrompt: acceptOpenPrompt, timeout: options.timeout)
                    }
                } else {
                    result.treeSession = "off"
                    out = try await timed("tree") {
                        try await ShotRunner.read(udid: device.udid, bundleID: bundleID, waitText: waitText,
                                                  acceptOpenPrompt: acceptOpenPrompt,
                                                  timeout: options.timeout, xctestrun: xctestrun)
                    }
                }
                result.tree = ShotTree.compact(out.root)
                result.treeElements = out.root.count
                rootWidth = out.root.frame.count == 4 ? out.root.frame[2] : nil
                result.treeStatus = "ok"
                result.treeNote = options.session
                    ? "XCTest XCUIApplication.snapshot() in a runner session kept alive for \(ShotSession.idleSeconds) s; frames in points."
                    : "XCTest XCUIApplication.snapshot() via xcodebuild test-without-building; frames in points."
                if waitText != nil { result.waitTextFound = out.waitTextFound }
                result.openPromptAccepted = out.openPromptAccepted
            } catch {
                result.treeStatus = "failed"
                result.treeNote = error.localizedDescription
            }
        }

        if options.url != nil, xctestrun == nil {
            result.urlNote = "iOS 27 may show an \"Open in …?\" prompt for a custom-scheme link; without the XCTest runner fast-ios cannot tap Open, so check the screenshot."
        }
        if xctestrun != nil, options.waitText != nil || options.url != nil {
            // The runner accepts the link prompt and waits for the text, then
            // reads the tree; the screenshot follows once the screen settles.
            await readTree(waitText: options.waitText, acceptOpenPrompt: options.url != nil)
            result.apply(try await timed("stableScreen") {
                try await stableScreenshot(device.udid, to: png, timeout: .seconds(5))
            })
        } else {
            if options.waitText != nil, result.treeStatus != "skipped" {
                result.treeNote = (result.treeNote ?? "") + " --wait text needs the tree, so this call waited for a stable screen instead."
            }
            result.apply(try await timed("stableScreen") {
                try await stableScreenshot(device.udid, to: png, timeout: options.timeout)
            })
            await readTree(waitText: nil, acceptOpenPrompt: false)
        }
        let image = try timedSync("resize") { try ShotImage.finish(png, maxWidth: options.maxWidth, scale: options.scale) }
        result.screenshotWidth = image.width
        result.screenshotHeight = image.height
        result.screenshotBytes = image.bytes
        if let rootWidth, rootWidth > 0 {
            result.pixelsPerPoint = (Double(image.width) / rootWidth * 1000).rounded() / 1000
        }
        result.totalMs = ms(clock.now - start)
        return result
    }

    // MARK: Steps

    static func bundleIdentifier(_ app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    /// The given simulator (booted if needed), else a booted slim iOS
    /// simulator, else a shut-down iPhone, slimmed for this app and booted.
    /// A booted simulator that is not slim is never rebooted.
    static func pickSimulator(_ selector: String?, app: URL, log: Log) async throws -> (SimDevice, String) {
        if let selector {
            let device = try await Simctl.resolve(selector)
            if !device.isBooted {
                log("Booting \(device.name)…")
                try await Simctl.bootAndWait(device.udid)
            }
            return (try await Simctl.device(device.udid), "given")
        }
        let devices = try await Simctl.listDevices().filter { $0.isAvailable && $0.runtimeName.hasPrefix("iOS") }
        func isSlim(_ d: SimDevice) -> Bool {
            !DisabledStore.disabledLabels(d.udid).intersection(ServiceCatalog.slimmable).isEmpty
        }
        if let booted = devices.first(where: { $0.isBooted && isSlim($0) }) { return (booted, "booted-slim") }

        let iphones = devices.filter { !$0.isBooted && ($0.deviceTypeIdentifier ?? $0.name).contains("iPhone") }
        // Prefer one fast-ios already slimmed, then the newest runtime.
        guard let pick = iphones.sorted(by: {
            (isSlim($0) ? 0 : 1, $1.runtimeIdentifier) < (isSlim($1) ? 0 : 1, $0.runtimeIdentifier)
        }).first else {
            throw ShotError(message: "No running light simulator and no stopped iPhone simulator to start. Pass --udid, or create one with `xcrun simctl create`.")
        }
        let facts = try await AppInspector.inspect(app)
        let (profile, _) = Profiler.derive(from: facts)
        log("Starting \(pick.name) light for \(facts.appName)…")
        _ = try await Slimmer.slim(pick, profile: profile, boot: true, log: log)
        return (try await Simctl.device(pick.udid), "booted-now")
    }

    /// True when the installed app has the same files (path, size, mtime) as
    /// the built one. `simctl install` copies the bundle verbatim and keeps
    /// modification dates, so a rebuilt app always differs.
    static func installedMatches(_ app: URL, bundleID: String, udid: String) async throws -> Bool {
        let container = try await Simctl.simctl("get_app_container", udid, bundleID, "app", check: false)
        guard container.status == 0 else { return false }
        let installed = URL(fileURLWithPath: container.text.trimmingCharacters(in: .whitespacesAndNewlines))
        return fingerprint(app) == fingerprint(installed)
    }

    static func fingerprint(_ bundle: URL) -> [String: String] {
        var out: [String: String] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let root = bundle.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: bundle.resolvingSymlinksInPath(),
                                                          includingPropertiesForKeys: keys) else { return out }
        while let item = walker.nextObject() as? URL {
            guard let v = try? item.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let rel = String(item.resolvingSymlinksInPath().path.dropFirst(root.count))
            let mtime = Int((v.contentModificationDate ?? .distantPast).timeIntervalSince1970)
            out[rel] = "\(v.fileSize ?? -1)@\(mtime)"
        }
        return out
    }

    /// Screenshots every 0.4 s until `needed` in a row are byte-identical
    /// (about one second of no change), or the timeout passes. The last
    /// screenshot is kept at `png` either way. A splash screen that holds
    /// longer than that still counts as stable: use --wait text for those.
    static func stableScreenshot(_ udid: String, to png: URL, timeout: Duration, needed: Int = 3) async throws -> Stability {
        let deadline = ContinuousClock.now + timeout
        var previous: ScreenPixels?
        var calm = 1
        var allIdentical = true
        var worst = 0.0
        while true {
            try await Simctl.simctl("io", udid, "screenshot", "--type=png", png.path)
            let current = ScreenPixels(png: png)
            if let previous, let current {
                let changed = current.changedFraction(from: previous)
                // A spinner or blinking caret changes a sliver of the screen;
                // below `smallChange` the screen counts as settled.
                if changed <= ScreenPixels.smallChange {
                    calm += 1
                    worst = max(worst, changed)
                    if changed > 0 { allIdentical = false }
                } else {
                    calm = 1; worst = 0; allIdentical = true
                }
            }
            if calm >= needed {
                return Stability(stable: true, kind: allIdentical ? "identical" : "small-animation", changedPercent: worst * 100)
            }
            if ContinuousClock.now >= deadline {
                return Stability(stable: false, kind: "still-changing", changedPercent: nil)
            }
            previous = current
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    public struct Stability: Sendable {
        public let stable: Bool
        /// "identical", "small-animation" (only a small area kept moving,
        /// such as a spinner) or "still-changing" (gave up at the timeout).
        public let kind: String
        public let changedPercent: Double?
    }

    static func ms(_ d: Duration) -> Int {
        Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }
}

public struct ShotError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}
