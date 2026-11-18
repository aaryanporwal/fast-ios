import Darwin
import Foundation

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
    /// Running simulators in this device set, largest first, as "name (udid)".
    public let simulatorsToStop: [String]
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

    /// Reads what is using memory and builds the advice. `devices` are the
    /// simulators of the current device set; `measured` their memory.
    public static func build(memory: MemoryStatus, policy: AdmissionPolicy, pendingBoots: Int = 0,
                             devices: [SimDevice], measured: [String: SimMeasurement],
                             otherSimulators: (count: Int, mb: Int) = (0, 0),
                             largestApps: [(name: String, mb: Int)]) -> MemoryAdvice {
        let (can, why) = judge(memory, policy: policy, pendingBoots: pendingBoots)
        let running = devices.filter(\.isBooted)
            .map { ($0, Int((measured[$0.udid]?.bytes ?? 0) / 1_048_576)) }
            .sorted { $0.1 > $1.1 }
        var usage: [String] = []
        if !running.isEmpty {
            let list = running.prefix(4).map { "\($0.0.name) \($0.1) MB" }.joined(separator: ", ")
            usage.append("Running simulators: \(list)\(running.count > 4 ? " and \(running.count - 4) more" : "").")
        }
        if otherSimulators.count > 0 {
            let n = otherSimulators.count
            let scope = Simctl.deviceSet == nil ? "in other device sets" : "outside this device set (--set)"
            usage.append("\(n) more simulator\(n == 1 ? "" : "s") \(scope) use\(n == 1 ? "s" : "") \(formatMB(otherSimulators.mb)).")
        }
        if !largestApps.isEmpty {
            usage.append("Largest apps: " + largestApps.prefix(3).map { "\($0.name) \(formatMB($0.mb))" }.joined(separator: ", ") + ".")
        }
        let stop = running.map { "\($0.0.name) (\($0.0.udid))" }
        var steps: [String] = []
        if let first = running.first {
            steps.append("Shut down a simulator you are not using, such as \(first.0.name): `xcrun simctl\(Simctl.deviceSet.map { " --set '\($0)'" } ?? "") shutdown \(first.0.udid)`.")
        } else {
            steps.append("Quit a large app you are not using.")
        }
        if memory.pressure == "warning", policy.maxPressure != "warning" {
            steps.append("Or start anyway with `--max-pressure warning` (the Mac may slow down while it pages).")
        }
        steps.append("Or use a simulator that is already running with `--simulator <udid>` (`fast-ios status` lists them).")
        return MemoryAdvice(canStartNew: can, why: why, usage: usage, simulatorsToStop: stop,
                            nextStep: steps.joined(separator: " "))
    }

    /// Reads devices, their memory and the largest apps, then builds the advice.
    public static func current(policy: AdmissionPolicy = AdmissionPolicy(), pendingBoots: Int = 0,
                               memory: MemoryStatus = .read()) async -> MemoryAdvice {
        let devices = ((try? await Simctl.listDevices()) ?? []).filter(\.isAvailable)
        let measured = await Measure.many(devices.filter(\.isBooted).map(\.udid))
        let others = await otherSimulators(excluding: Set(devices.map { $0.udid.uppercased() }))
        return build(memory: memory, policy: policy, pendingBoots: pendingBoots, devices: devices,
                     measured: measured, otherSimulators: others, largestApps: largestApps())
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
