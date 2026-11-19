import Darwin
import Foundation

/// One running simulator, as a memory refusal lists it.
public struct RunningSimulator: Codable, Sendable, Equatable {
    public let udid: String
    public let name: String
    /// Memory of every process in the simulator, added up.
    public let memoryMB: Int
    /// The lease owner when an agent holds it, else nil.
    public let leasedBy: String?
    /// True when fast-ios created it for the pool (`run`, `lease`).
    public let fromPool: Bool
    /// Bundle IDs of the non-Apple apps running on it. fast-ios sees which
    /// apps run, not which one is in front.
    public let appsRunning: [String]

    public init(udid: String, name: String, memoryMB: Int, leasedBy: String?, fromPool: Bool, appsRunning: [String]) {
        self.udid = udid; self.name = name; self.memoryMB = memoryMB
        self.leasedBy = leasedBy; self.fromPool = fromPool; self.appsRunning = appsRunning
    }

    enum CodingKeys: String, CodingKey { case udid, name, memoryMB, leasedBy, fromPool, appsRunning }

    /// `leasedBy` is null, not left out, when nobody holds it.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(udid, forKey: .udid); try c.encode(name, forKey: .name); try c.encode(memoryMB, forKey: .memoryMB)
        try c.encode(leasedBy, forKey: .leasedBy); try c.encode(fromPool, forKey: .fromPool)
        try c.encode(appsRunning, forKey: .appsRunning)
    }

    /// "iPhone 17 Pro (UDID): 2104 MB, leased by claude[123], apps running: com.x."
    var line: String {
        let holder = leasedBy.map { "leased by \($0)" } ?? (fromPool ? "free in the fast-ios pool" : "not from the fast-ios pool")
        let apps = appsRunning.isEmpty ? "" : ", apps running: " + appsRunning.joined(separator: ", ")
        return "- \(name) (\(udid)): \(memoryMB) MB, \(holder)\(apps)."
    }
}

/// One app on the Mac, outside the simulators.
public struct AppMemory: Codable, Sendable, Equatable {
    public let name: String
    public let memoryMB: Int
}

/// Why a new simulator cannot start right now, what is using the memory, and
/// what to do about it, in plain words. One source for the lease refusal,
/// `run`'s error and `doctor`, so they always agree.
public struct MemoryAdvice: Sendable, Equatable {
    /// True when a new simulator may start now under `policy`.
    public let canStartNew: Bool
    /// One sentence: why not (empty when it can start).
    public let why: String
    /// What uses the most memory: running simulators first, then the largest apps.
    public let usage: [String]
    /// Running simulators in this device set, largest first.
    public let simulators: [RunningSimulator]
    /// The largest apps outside the simulators, largest first.
    public let largestApps: [AppMemory]
    /// The next step, as one or two sentences with exact commands.
    public let nextStep: String

    /// The rule `lease`, `run` and `doctor` share.
    public static func judge(_ memory: MemoryStatus, policy: AdmissionPolicy, pendingBoots: Int = 0) -> (canStart: Bool, why: String) {
        if policy.admits(memory, pendingBoots: pendingBoots) { return (true, "") }
        return (false, sentence(memory, policy: policy, pendingBoots: pendingBoots))
    }

    /// The reason in plain words.
    static func sentence(_ m: MemoryStatus, policy: AdmissionPolicy, pendingBoots: Int) -> String {
        if m.pressure == "critical" {
            return "macOS reports memory pressure as critical (\(m.availableMB) MB free), and fast-ios never starts a simulator then."
        }
        if !policy.pressureOK(m) {
            return "macOS reports memory pressure as \(m.pressure) (\(m.availableMB) MB free), and fast-ios starts a new simulator only at normal pressure."
        }
        let need = policy.needMB * (pendingBoots + 1) + policy.reserveMB
        let pending = pendingBoots > 0 ? " for \(pendingBoots + 1) simulators starting at once" : ""
        return "Only \(m.availableMB) MB is free; a new simulator needs \(need) MB\(pending) (\(policy.needMB) MB for it, \(policy.reserveMB) MB left for the rest of the Mac)."
    }

    /// Builds the advice from what was read. `devices` are the simulators of
    /// the current device set; `measured` their memory; `leasedBy` maps a
    /// leased UDID to its owner; `pool` holds the UDIDs fast-ios created;
    /// `apps` maps a UDID to the non-Apple apps running on it.
    public static func build(memory: MemoryStatus, policy: AdmissionPolicy, pendingBoots: Int = 0,
                             devices: [SimDevice], measured: [String: SimMeasurement],
                             leasedBy: [String: String] = [:], pool: Set<String> = [],
                             apps: [String: [String]] = [:],
                             otherSimulators: (count: Int, mb: Int) = (0, 0),
                             largestApps: [(name: String, mb: Int)]) -> MemoryAdvice {
        let (can, why) = judge(memory, policy: policy, pendingBoots: pendingBoots)
        let running = devices.filter(\.isBooted)
            .map { d in
                RunningSimulator(udid: d.udid, name: d.name, memoryMB: Int((measured[d.udid]?.bytes ?? 0) / 1_048_576),
                                 leasedBy: leasedBy[d.udid], fromPool: pool.contains(d.udid), appsRunning: apps[d.udid] ?? [])
            }
            .sorted { $0.memoryMB > $1.memoryMB }
        var usage: [String] = []
        if !running.isEmpty {
            let seesApps = running.contains { !$0.appsRunning.isEmpty }
            usage.append("Running simulators, largest first\(seesApps ? " (fast-ios sees which apps run, not which one is in front)" : ""):")
            usage += running.prefix(4).map(\.line)
            if running.count > 4 { usage.append("- and \(running.count - 4) more (`fast-ios status` lists them).") }
        }
        if otherSimulators.count > 0 {
            let n = otherSimulators.count
            let scope = Simctl.deviceSet == nil ? "in other device sets" : "outside this device set (--set)"
            usage.append("\(n) more simulator\(n == 1 ? "" : "s") \(scope) use\(n == 1 ? "s" : "") \(formatMB(otherSimulators.mb)).")
        }
        let apps = largestApps.prefix(3).map { AppMemory(name: $0.name, memoryMB: $0.mb) }
        if !apps.isEmpty {
            usage.append("Largest apps: " + apps.map { "\($0.name) \(formatMB($0.memoryMB))" }.joined(separator: ", ") + ".")
        }
        // The choices, cheapest first: reuse, start anyway, free memory.
        var steps: [String] = []
        let free = running.filter { $0.leasedBy == nil }
        if let reuse = free.first {
            steps.append("Reuse a running simulator no agent leases with `--simulator <udid>` (check its apps first), such as \(reuse.name): `fast-ios run --simulator \(reuse.udid)`.")
        } else if !running.isEmpty {
            steps.append("Every running simulator is leased by an agent; reuse one with `--simulator <udid>` only if that lease is yours.")
        }
        if memory.pressure == "warning", policy.maxPressure != "warning" {
            steps.append("\(steps.isEmpty ? "Start" : "Or start") a new one anyway with `--max-pressure warning` (the Mac may slow down while it pages).")
        }
        let set = Simctl.deviceSet.map { " --set '\($0)'" } ?? ""
        if let stop = free.first {
            steps.append("\(steps.isEmpty ? "Shut" : "Or shut") down a simulator you are not using, such as \(stop.name): `xcrun simctl\(set) shutdown \(stop.udid)`.")
        } else {
            steps.append("\(steps.isEmpty ? "Quit" : "Or quit") a large app you are not using.")
        }
        return MemoryAdvice(canStartNew: can, why: why, usage: usage, simulators: running, largestApps: apps,
                            nextStep: steps.joined(separator: " "))
    }

    /// Reads devices, their memory, leases and the largest apps, then builds
    /// the advice. `withApps` also asks each running simulator which apps run
    /// (about 0.4 s, all simulators at once).
    public static func current(policy: AdmissionPolicy = AdmissionPolicy(), pendingBoots: Int = 0,
                               memory: MemoryStatus = .read(), withApps: Bool = false) async -> MemoryAdvice {
        let devices = ((try? await Simctl.listDevices()) ?? []).filter(\.isAvailable)
        let booted = devices.filter(\.isBooted).map(\.udid)
        async let measuredTask = Measure.many(booted)
        async let appsTask = withApps ? runningApps(booted) : [:]
        let others = await otherSimulators(excluding: Set(devices.map { $0.udid.uppercased() }))
        var state = LeaseStore.load()
        _ = state.reap()  // a lease whose owner exited does not count
        return build(memory: memory, policy: policy, pendingBoots: pendingBoots, devices: devices,
                     measured: await measuredTask, leasedBy: state.leases.mapValues(\.owner),
                     pool: Set(state.pool.values.filter { !$0.adopted }.map(\.udid)), apps: await appsTask,
                     otherSimulators: others, largestApps: largestApps())
    }

    /// The non-Apple apps running on each simulator, from its launchd jobs
    /// (`UIKitApplication:<bundle id>[…]`).
    static func runningApps(_ udids: [String]) async -> [String: [String]] {
        await withTaskGroup(of: (String, [String]).self) { group in
            for udid in udids {
                group.addTask {
                    let text = (try? await Simctl.simctl("spawn", udid, "launchctl", "list", check: false).text) ?? ""
                    return (udid, appIDs(fromLaunchctlList: text))
                }
            }
            var out: [String: [String]] = [:]
            for await (udid, ids) in group { out[udid] = ids }
            return out
        }
    }

    /// Bundle IDs from `launchctl list` inside a simulator, Apple's left out.
    static func appIDs(fromLaunchctlList text: String) -> [String] {
        var seen: [String] = []
        for line in text.split(separator: "\n") {
            guard let r = line.range(of: "UIKitApplication:") else { continue }
            let id = String(line[r.upperBound...].prefix { $0 != "[" && !$0.isWhitespace })
            if id.isEmpty || id.hasPrefix("com.apple.") || seen.contains(id) { continue }
            seen.append(id)
        }
        return seen
    }

    /// The host's three largest processes by memory, simulator processes left
    /// out (they are listed per simulator). Only processes this user may read.
    public static func largestApps(limit: Int = 3) -> [(name: String, mb: Int)] {
        let table = ProcessTable.all()
        let roots = Set(ProcessTable.simulatorRoots(table).values)
        // Every descendant of a launchd_sim belongs to a simulator.
        var parent: [Int32: Int32] = [:]
        for e in table { parent[e.pid] = e.ppid }
        func inSimulator(_ pid: Int32) -> Bool {
            var p = pid
            for _ in 0..<32 {
                if roots.contains(p) { return true }
                guard let next = parent[p], next > 1, next != p else { return false }
                p = next
            }
            return false
        }
        var byName: [String: Int64] = [:]
        for e in table where e.pid > 1 && !inSimulator(e.pid) && e.name != "launchd_sim" {
            guard let bytes = ProcessTable.footprint(e.pid) else { continue }
            byName[appName(e.pid) ?? e.name, default: 0] += bytes
        }
        return byName.sorted { $0.value > $1.value }.prefix(limit)
            .map { (name: $0.key, mb: Int($0.value / 1_048_576)) }
            .filter { $0.mb >= 200 }
    }

    /// The app a process belongs to, by its executable path: the outermost
    /// "X.app" folder ("Google Chrome" for its helpers), else the file name.
    static func appName(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name(fromExecutablePath: path)
    }

    static func name(fromExecutablePath path: String) -> String {
        let parts = path.split(separator: "/")
        if let app = parts.first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
        return parts.last.map(String.init) ?? path
    }

    /// Simulators running outside the current device set: count and memory.
    static func otherSimulators(excluding udids: Set<String>) async -> (count: Int, mb: Int) {
        let roots = ProcessTable.simulatorRoots(ProcessTable.all()).keys.filter { !udids.contains($0.uppercased()) }
        guard !roots.isEmpty else { return (0, 0) }
        let m = await Measure.many(Array(roots))
        return (roots.count, Int(m.values.reduce(0) { $0 + $1.bytes } / 1_048_576))
    }

    static func formatMB(_ mb: Int) -> String {
        mb >= 1000 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }
}
