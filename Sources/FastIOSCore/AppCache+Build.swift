import Foundation

/// Who holds a build lock, written into the lock file for the agents that wait.
public struct BuildHolder: Sendable, Codable, Equatable {
    public let pid: Int32
    public let startedAt: Date
    public let command: String
}

/// What a caller of `AppCache.obtain` got.
public enum ObtainOutcome: Sendable, Equatable {
    /// Already stored.
    case hit(CachedApp)
    /// This call built and stored it.
    case built(CachedApp)
    /// Another process built it while this one waited.
    case waited(CachedApp, seconds: Double)
}

/// A build that fast-ios runs on a miss: returns the .app it produced and
/// how long it took. Tests pass fakes.
public typealias AppBuilder = @Sendable () async throws -> (app: URL, seconds: Double)

extension AppCache {
    /// The stored app for `fp`, building it with `build` on a miss.
    ///
    /// Single flight: one process builds a fingerprint at a time. The others
    /// wait for its result, then reuse it. The lock is a `flock` on
    /// `.locks/<fingerprint>.lock`, which the kernel releases when the
    /// builder exits, so a crashed builder never blocks the others: the next
    /// waiter takes the lock and builds. After `timeout` a waiter gives up
    /// with an error that says who is building.
    public static func obtain(_ fp: AppFingerprint, projectName: String, variant: String? = nil,
                              command: String, timeout: TimeInterval = 20 * 60, poll: TimeInterval = 0.5,
                              log: @escaping Log = { _ in }, build: AppBuilder) async throws -> ObtainOutcome {
        if let hit = lookup(fp) { return .hit(hit) }
        let locks = folder.appendingPathComponent(".locks", isDirectory: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let lockURL = locks.appendingPathComponent("\(fp.hash).lock")
        let start = Date()
        var toldWaiting = false
        while true {
            let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw AppCacheError("Cannot open the build lock \(lockURL.path) (errno \(errno)). Check that the folder is writable.") }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                defer { flock(fd, LOCK_UN); close(fd) }
                // Someone may have finished between our lookup and the lock.
                if let hit = lookup(fp) {
                    let waited = Date().timeIntervalSince(start)
                    return toldWaiting ? .waited(hit, seconds: waited) : .hit(hit)
                }
                let holder = BuildHolder(pid: getpid(), startedAt: Date(), command: command)
                if let data = try? encoder.encode(holder) {
                    ftruncate(fd, 0)
                    _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, 0) }
                }
                if toldWaiting { log("The other build stopped without storing an app; building it here.") }
                let (app, seconds) = try await build()
                let stored = try await add(app, fingerprint: fp, projectName: projectName, variant: variant, buildSeconds: seconds)
                ftruncate(fd, 0)
                return .built(stored)
            }
            let holder = (try? Data(contentsOf: lockURL)).flatMap { try? decoder.decode(BuildHolder.self, from: $0) }
            close(fd)
            let waited = Date().timeIntervalSince(start)
            if !toldWaiting {
                toldWaiting = true
                let who = holder.map { "Another agent (process \($0.pid)) started building this app \(Int(Date().timeIntervalSince($0.startedAt))) s ago" }
                    ?? "Another agent is building this app"
                log("\(who); waiting for it (up to \(LeaseManager.duration(timeout))) instead of building it twice.")
            }
            if waited >= timeout {
                let who = holder.map { "process \($0.pid), running `\($0.command)`" } ?? "another process"
                throw AppCacheError("Waited \(LeaseManager.duration(timeout)) for \(who) to build this app, and it is still building. Nothing was installed. Next: run the same command again later, or pass a longer --build-timeout.")
            }
            try await Task.sleep(for: .seconds(poll))
            if let hit = lookup(fp) { return .waited(hit, seconds: Date().timeIntervalSince(start)) }
        }
    }
}

/// How `run` and `shot` use the app cache for a project folder.
public struct AppCacheRequest: Sendable {
    /// Shell command that builds the app, run in the project folder on a miss.
    public var build: String?
    /// Where the build puts the .app, relative to the project folder. When
    /// nil, the newest simulator build in the project is used.
    public var builtApp: String?
    public var options = FingerprintOptions()
    public var timeout: TimeInterval = 20 * 60
    public init() {}
}

public struct AppCacheResolution: Sendable {
    /// nil on a miss with no --build: the caller looks for a local build.
    public let app: URL?
    /// For RunOutput.appSource.
    public let source: String
    public let summary: AppCacheSummary
}

extension AppCache {
    /// A folder `run` treats as a project (so the cache may apply): not an
    /// .app, and it has an Xcode project, a Swift package or a package.json.
    public static func isProjectFolder(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard url.pathExtension != "app", FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") || $0 == "Package.swift" || $0 == "package.json" || $0 == "ios" }
    }

    /// The app to install for the project in `folder`: a stored one on a hit,
    /// a fresh build on a miss when `request.build` is set. Returns nil when
    /// the cache does not apply (nothing stored for this project and no
    /// --build), and a resolution with no app on a miss without --build; then
    /// the caller falls back to finding a local build. Throws
    /// NotCacheable when the project cannot be cached.
    public static func resolve(project folder: String, _ request: AppCacheRequest,
                               log: @escaping Log = { _ in }) async throws -> AppCacheResolution? {
        if request.build == nil, !hasEntries(projectID: await Fingerprinter.projectID(folder)) { return nil }
        let t0 = Date()
        let fp = try await Fingerprinter.compute(folder, options: request.options)
        let fpSeconds = Date().timeIntervalSince(t0)
        let what = fp.kind == .expo ? "native code" : "source files"
        let name = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.lastPathComponent
        if let hit = lookup(fp) {
            return resolution(.hit(hit), fp: fp, what: what, fpSeconds: fpSeconds, log: log)
        }
        guard let command = request.build else {
            let message = "No stored app matches this project (fingerprint \(fp.short)): its \(what) changed since the last stored build. Store a build with `fast-ios apps add <app> --project \(folder)`, or pass --build \"<command>\" to build and store it. `fast-ios apps why \(folder)` shows what changed."
            log(message)
            return AppCacheResolution(app: nil, source: "", summary: AppCacheSummary(status: "miss", fingerprint: fp.hash, kind: fp.kind,
                                                                                    builtAt: nil, savedSeconds: nil, message: message))
        }
        let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL
        let builtApp = request.builtApp
        let configuration = request.options.configuration
        let builder: AppBuilder = {
            log("No stored app for fingerprint \(fp.short); building it with `\(command)`…")
            return try await runBuild(command, in: root, builtApp: builtApp, configuration: configuration)
        }
        let outcome = try await obtain(fp, projectName: name, variant: request.options.variant, command: command,
                                       timeout: request.timeout, log: log, build: builder)
        return resolution(outcome, fp: fp, what: what, fpSeconds: fpSeconds, log: log)
    }

    static func resolution(_ outcome: ObtainOutcome, fp: AppFingerprint, what: String, fpSeconds: Double,
                           log: Log) -> AppCacheResolution {
        switch outcome {
        case .hit(let m):
            let saved = m.buildSeconds.map { " Skipped a compile that took \(Bench.fmt($0)) s." } ?? ""
            let message = "Reused the app built \(ago(m.builtAt)): \(what) unchanged.\(saved)"
            log(message)
            return AppCacheResolution(app: appURL(m), source: "app cache, fingerprint \(fp.short)",
                                      summary: AppCacheSummary(status: "hit", fingerprint: fp.hash, kind: fp.kind, builtAt: iso(m.builtAt), savedSeconds: m.buildSeconds.map { (max(0, $0 - fpSeconds) * 10).rounded() / 10 }, message: message))
        case .built(let m):
            let message = "Built and stored the app in \(Bench.fmt(m.buildSeconds ?? 0)) s; the next run with the same \(what) reuses it."
            log(message)
            return AppCacheResolution(app: appURL(m), source: "built with --build, stored as \(fp.short)",
                                      summary: AppCacheSummary(status: "built", fingerprint: fp.hash, kind: fp.kind, builtAt: iso(m.builtAt), savedSeconds: nil, message: message))
        case .waited(let m, let seconds):
            let message = "Another agent built this app while this one waited \(Bench.fmt(seconds)) s; reusing it."
            log(message)
            return AppCacheResolution(app: appURL(m), source: "app cache, built by another agent, fingerprint \(fp.short)",
                                      summary: AppCacheSummary(status: "waited", fingerprint: fp.hash, kind: fp.kind, builtAt: iso(m.builtAt), savedSeconds: m.buildSeconds.map { (max(0, $0 - seconds) * 10).rounded() / 10 }, message: message))
        }
    }

    /// Runs the build command in `root` with `/bin/sh -c`, and finds the app.
    /// Output goes to `.logs/<time>.log`; a failure shows its last lines.
    static func runBuild(_ command: String, in root: URL, builtApp: String?, configuration: String) async throws -> (app: URL, seconds: Double) {
        let logs = folder.appendingPathComponent(".logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent("build-\(Int(Date().timeIntervalSince1970))-\(getpid()).log")
        let start = Date()
        let r = try await Shell.run("/bin/sh", ["-c", "cd \(shellQuote(root.path)) && \(command) > \(shellQuote(logURL.path)) 2>&1"], check: false)
        let seconds = (Date().timeIntervalSince(start) * 10).rounded() / 10
        guard r.status == 0 else {
            let tail = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").suffix(15).joined(separator: "\n")
            throw AppCacheError("The build command failed (exit \(r.status)) after \(Bench.fmt(seconds)) s, so nothing was stored or installed. Last lines:\n\(tail)\nFull log: \(logURL.path). Next: fix the build, then run again.")
        }
        let app: URL
        if let builtApp {
            app = URL(fileURLWithPath: builtApp, relativeTo: root).standardizedFileURL
            guard FileManager.default.fileExists(atPath: app.path) else {
                throw AppCacheError("The build finished, but \(app.path) does not exist. Check --built-app: it is the .app path the build writes, relative to the project folder.")
            }
        } else {
            guard let (found, _) = try? AppRunner.findBuild(in: root.path) else {
                throw AppCacheError("The build finished, but fast-ios found no simulator .app in the project (ios/build, build, DerivedData). Pass --built-app <path to the .app> to say where the build writes it.")
            }
            app = found
        }
        if let c = AppCache.configuration(fromPath: app.path), c != configuration {
            throw AppCacheError("The build produced a \(c) app (\(app.path)), but the configuration is \(configuration). Pass --configuration \(c), or make the build command build \(configuration).")
        }
        return (app, seconds)
    }

    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// "2 hours ago", "40 s ago".
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "\(s) s ago"
        case ..<3600: return "\(s / 60) min ago"
        case ..<172_800: return s / 3600 == 1 ? "1 hour ago" : "\(s / 3600) hours ago"
        default: return "\(s / 86_400) days ago"
        }
    }
}
