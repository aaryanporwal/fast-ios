import Foundation

public struct HealOptions: Sendable {
    /// Stop after this long; nil runs until cancelled.
    public var duration: TimeInterval?
    /// After a repair attempt, ignore the same service for this long.
    public var cooldown: TimeInterval = 30
    /// Most services one heal run may turn on.
    public var maxRepairs = 10
    public init() {}
}

/// Follows a booted simulator's log, sees the app fail to reach a service
/// fast-ios turned off, turns that service on without a reboot, and saves it
/// to the app's profile.
///
/// Proved on iOS 27.0 (15 Nov 2026) for photos (assetsd) and contacts
/// (contactsd): the app's own process logs the failed call with the Mach
/// service name, and `launchctl enable` + `bootstrap` makes the next call
/// work. Only the app's process is watched. Push is requested through
/// SpringBoard, which logged the failure once in three runs and also calls
/// apsd on its own timer, so push is left to the profile (`aps-environment`
/// keeps apsd, even with --strict). That every service fails this visibly is
/// not proved.
public enum Healer {
    /// Failure lines seen in the feasibility test, each naming a Mach service:
    ///   NSCocoaErrorDomain Code=4099 "The connection to service named com.apple.photos.service …"
    ///   Service connection to com.apple.contactsd was invalidated
    ///   Connection Invalid for service com.apple.apsd (SpringBoard)
    nonisolated(unsafe) static let patterns: [Regex<(Substring, Substring)>] = [
        #/service named ([A-Za-z0-9._\-]+)/#,
        #/[Cc]onnection to ([A-Za-z0-9._\-]+) was invalidated/#,
        #/Connection Invalid for service ([A-Za-z0-9._\-]+)/#,
    ]
    /// `2026-11-15 18:40:12.483 E  Probe[5695:10f90d9] [subsystem:category] message`
    nonisolated(unsafe) static let compactLine = #/^\S+ \S+\s+\S+\s+([^\[\s]+)\[\d+:[0-9a-fx]+\] (.*)$/#

    public struct Failure: Sendable, Hashable {
        public let process: String
        public let machService: String
        public let line: String
    }

    /// The failure a compact log line reports, if any, from one of
    /// `processes` (nil: any process).
    public static func failure(in line: String, processes: Set<String>?) -> Failure? {
        guard let m = line.firstMatch(of: compactLine) else { return nil }
        let process = String(m.1)
        if let processes, !processes.contains(process) { return nil }
        for p in patterns {
            if let f = m.2.firstMatch(of: p) {
                return Failure(process: process, machService: String(f.1), line: String(line.prefix(400)))
            }
        }
        return nil
    }

    /// Heals one app: follows only its process.
    public static func run(device: SimDevice, bundleID: String, executable: String, options: HealOptions,
                           emit: @escaping @Sendable (HealEvent) -> Void) async throws {
        try await follow(device: device, subject: bundleID, subjectProcess: executable,
                         predicate: "process == \"\(executable)\"",
                         resolve: { $0 == executable ? bundleID : nil }, options: options, emit: emit)
    }

    /// Heals every app the user installed on the simulator (what `fast-ios on`
    /// runs). The log is filtered to failure lines on the simulator side, and
    /// a line counts only when its process is an installed user app; the
    /// service is learned for that app's bundle id.
    public static func runForUserApps(device: SimDevice, options: HealOptions,
                                      emit: @escaping @Sendable (HealEvent) -> Void) async throws {
        let apps = UserApps(udid: device.udid)
        try await follow(device: device, subject: "user apps", subjectProcess: nil,
                         predicate: "eventMessage CONTAINS \"service named\" OR eventMessage CONTAINS \"was invalidated\" OR eventMessage CONTAINS \"Connection Invalid\"",
                         resolve: { await apps.bundleID(forExecutable: $0) }, options: options, emit: emit)
    }

    /// `resolve` maps a process name to the bundle id the repair is learned
    /// for, or nil to ignore the line.
    static func follow(device: SimDevice, subject: String, subjectProcess: String?, predicate: String,
                       resolve: @escaping @Sendable (String) async -> String?, options: HealOptions,
                       emit: @escaping @Sendable (HealEvent) -> Void) async throws {
        guard device.isBooted else { throw SimctlError(message: "\(device.name) is not running. Start it first, then run heal again.") }
        let map = try await ServiceMap.load(runtimeIdentifier: device.runtimeIdentifier)

        var started = HealEvent(event: "healing", udid: device.udid, bundleIdentifier: subject)
        started.process = subjectProcess
        started.why = "following the log of \(subjectProcess ?? "every installed app"); cool-down \(Int(options.cooldown)) s, at most \(options.maxRepairs) repairs"
        emit(started)

        let logProcess = Process()
        logProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        let set = Simctl.deviceSet.map { ["--set", $0] } ?? []
        logProcess.arguments = ["simctl"] + set + ["spawn", device.udid, "log", "stream", "--style", "compact", "--level", "debug",
                                                   "--predicate", predicate]
        let pipe = Pipe()
        logProcess.standardOutput = pipe
        logProcess.standardError = FileHandle.nullDevice
        try logProcess.run()
        let handle = ProcessHandle(logProcess)
        defer { handle.terminate() }

        let deadlineTask = options.duration.map { d in
            Task { try? await Task.sleep(for: .seconds(d)); handle.terminate() }
        }
        defer { deadlineTask?.cancel() }

        var decider = HealDecider(cooldown: options.cooldown, maxRepairs: options.maxRepairs)
        for try await line in pipe.fileHandleForReading.bytes.lines {
            if Task.isCancelled { break }
            guard let f = failure(in: line, processes: nil) else { continue }
            guard let bundleID = await resolve(f.process) else { continue }
            let detected = Date()
            // launchd_sim rewrites the store on every enable and disable, so
            // it is current, and reading it costs no simctl spawn.
            let decision = decider.decide(f, map: map, disabled: { DisabledStore.disabledLabels(device.udid) }, now: detected)
            let label: String
            switch decision {
            case .silent:
                continue
            case .ignore(let l, let why):
                var e = HealEvent(event: "ignored", udid: device.udid, bundleIdentifier: bundleID)
                e.label = l; e.machService = f.machService; e.process = f.process; e.why = why; e.evidence = f.line
                emit(e)
                continue
            case .capReached(let l, let why):
                var e = HealEvent(event: "cap-reached", udid: device.udid, bundleIdentifier: bundleID)
                e.label = l; e.machService = f.machService; e.why = why
                emit(e)
                continue
            case .repair(let l):
                label = l
            }
            var e = HealEvent(event: "repaired", udid: device.udid, bundleIdentifier: bundleID)
            e.label = label; e.machService = f.machService; e.process = f.process; e.evidence = f.line
            e.why = "\(f.process) failed to reach \(f.machService), served by \(label), which fast-ios had turned off"
            do {
                try await enableLive(udid: device.udid, label: label, plist: map.plistForLabel[label])
                e.repairMs = Int(Date().timeIntervalSince(detected) * 1000)
                try HealStore.learn(LearnedService(label: label, machService: f.machService, evidence: f.line,
                                                   learnedAt: Date(), udid: device.udid), bundleID: bundleID)
                e.savedToProfile = true
            } catch {
                e = HealEvent(event: "repair-failed", udid: device.udid, bundleIdentifier: bundleID)
                e.label = label; e.machService = f.machService; e.process = f.process; e.evidence = f.line
                e.why = error.localizedDescription
            }
            HealStore.record(e)
            emit(e)
        }
        var stopped = HealEvent(event: "stopped", udid: device.udid, bundleIdentifier: subject)
        stopped.why = "turned on \(decider.repairs) service(s)"
        emit(stopped)
    }

    /// `launchctl enable` lifts the override (launchd_sim also writes it to
    /// the store, so it holds across reboots); `bootstrap` loads the job now.
    static func enableLive(udid: String, label: String, plist: String?) async throws {
        try await Simctl.simctl("spawn", udid, "launchctl", "enable", "system/\(label)")
        if let plist {
            // Fails harmlessly when launchd already loaded it on demand.
            _ = try? await Simctl.simctl("spawn", udid, "launchctl", "bootstrap", "system", plist, check: false)
        }
        let loaded = try await Simctl.simctl("spawn", udid, "launchctl", "print", "system/\(label)", check: false)
        guard loaded.status == 0 else {
            throw SimctlError(message: "\(label) is enabled but launchd did not load it.")
        }
    }

    /// The app's executable name, from a .app path or an installed bundle id.
    public static func appIdentity(_ app: String, udid: String) async throws -> (bundleID: String, executable: String) {
        var appURL: URL
        if app.hasSuffix(".app") || app.contains("/") {
            appURL = try AppInspector.locateApp(app)
        } else {
            let path = try await Simctl.simctl("get_app_container", udid, app, "app").text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            appURL = URL(fileURLWithPath: path)
        }
        appURL = appURL.standardizedFileURL
        guard let data = try? Data(contentsOf: appURL.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else {
            throw InspectError(message: "\(appURL.path) has no readable Info.plist with a bundle identifier.")
        }
        return (bundleID, info["CFBundleExecutable"] as? String ?? appURL.deletingPathExtension().lastPathComponent)
    }
}

/// What heal does about one failure line: map the Mach service to a label,
/// skip protected labels, apply the cool-down and the cap, and report each
/// ignored case once. No I/O except the `disabled` closure, so it is
/// testable without a simulator.
public struct HealDecider: Sendable {
    public enum Decision: Sendable, Equatable {
        /// Turn this label on.
        case repair(label: String)
        /// Not ours to fix; emit an "ignored" event (first time only).
        case ignore(label: String?, why: String)
        /// The run hit --max-repairs; emit "cap-reached" (once per label).
        case capReached(label: String, why: String)
        /// Nothing to emit: protected, cooling down, or already reported.
        case silent
    }

    public let cooldown: TimeInterval
    public let maxRepairs: Int
    public private(set) var repairs = 0
    private var lastAttempt: [String: Date] = [:]
    private var reported = Set<String>()

    public init(cooldown: TimeInterval, maxRepairs: Int) {
        self.cooldown = cooldown
        self.maxRepairs = maxRepairs
    }

    /// `disabled` is read only when a decision needs it.
    public mutating func decide(_ f: Healer.Failure, map: ServiceMap, disabled: () -> Set<String>,
                                now: Date) -> Decision {
        func once(_ key: String, _ d: Decision) -> Decision { reported.insert(key).inserted ? d : .silent }
        // Some clients log the short name ("assetsd") instead of the Mach service.
        guard let label = map.labelForMach[f.machService] ?? map.labelForMach["com.apple.\(f.machService)"] else {
            let why = "\(f.machService) is not a service fast-ios turns off"
            return once("\(f.machService)|\(why)", .ignore(label: nil, why: why))
        }
        if NeverDisable.isProtected(label) { return .silent }
        if let last = lastAttempt[label], now.timeIntervalSince(last) < cooldown { return .silent }
        guard disabled().contains(label) else {
            let why = "\(label) is not disabled, so the failure has another cause"
            return once("\(f.machService)|\(why)", .ignore(label: label, why: why))
        }
        guard repairs < maxRepairs else {
            return once("cap|\(label)", .capReached(
                label: label, why: "already turned on \(repairs) services in this run (--max-repairs)"))
        }
        lastAttempt[label] = now
        repairs += 1
        return .repair(label: label)
    }
}

/// The log process is only terminated, from any task; Process is thread-safe for that.
final class ProcessHandle: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}
