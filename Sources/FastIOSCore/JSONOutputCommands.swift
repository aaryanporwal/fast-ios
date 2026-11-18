import Foundation
import Synchronization

/// The commands as functions that return their JSON output types. The MCP
/// tools and `--json` both call these; nothing here writes to stdout.
public enum FastIOSCommands {
    /// The profile `slim` and `watch` use: from `app`, else `--full`, else the
    /// last derived profile, else the full catalog. `keep` adds labels.
    public static func resolveProfile(app: String?, keep: [String], full: Bool, strict: Bool = false) async throws -> (SlimProfile, [CapabilityRule]) {
        try KeepNames.validate(keep)
        if let app {
            let facts = try await AppInspector.inspect(try AppInspector.locateApp(app))
            return Profiler.derive(from: facts, keeping: keep, strict: strict)
        }
        if full { return (Profiler.full(keeping: keep), []) }
        if var saved = StateStore.load().defaultProfile {
            if !keep.isEmpty {
                var merged = saved.keep
                Profiler.addKept(keep, to: &merged)
                saved = Profiler.build(name: saved.name, appPath: saved.appPath, keep: merged)
            }
            return (saved, [])
        }
        return (Profiler.full(keeping: keep), [])
    }

    public static func status() async throws -> StatusOutput {
        let devices = try await Simctl.listDevices().filter(\.isAvailable)
        let state = StateStore.load()
        let mem = await Measure.many(devices.filter(\.isBooted).map(\.udid))
        let rows = devices.map { d in
            let off = DisabledStore.disabledLabels(d.udid).intersection(ServiceCatalog.slimmable).count
            let m = mem[d.udid]
            return SimulatorStatus(
                udid: d.udid, name: d.name, runtime: d.runtimeName, runtimeIdentifier: d.runtimeIdentifier,
                deviceType: d.deviceTypeIdentifier, state: d.state, slim: off > 0, disabledCount: off,
                profileName: state.devices[d.udid]?.profileName ?? (off > 0 ? "set outside fast-ios" : nil),
                processes: m?.processes, memoryBytes: m?.bytes)
        }
        return StatusOutput(deviceSet: Simctl.deviceSet, simulators: rows)
    }

    public static func profile(app: String, keep: [String]) async throws -> ProfileOutput {
        try KeepNames.validate(keep)
        let facts = try await AppInspector.inspect(try AppInspector.locateApp(app))
        let (profile, matches) = Profiler.derive(from: facts, keeping: keep)
        return ProfileOutput(
            app: facts.appPath, bundleIdentifier: facts.bundleIdentifier, profile: profile,
            matchedRules: matches.map { MatchedRule(trigger: $0.trigger.description, reason: $0.reason, keep: $0.keep) },
            catalogCount: ServiceCatalog.slimmable.count, neverDisabled: NeverDisable.labels.keys.sorted())
    }

    public static func slim(simulator: String, app: String?, keep: [String], full: Bool, boot: Bool, strict: Bool = false) async throws -> SlimOutput {
        let device = try await Simctl.resolve(simulator)
        let (profile, _) = try await resolveProfile(app: app, keep: keep, full: full, strict: strict)
        if app != nil, profile.appPath != nil {
            try StateStore.update { $0.defaultProfile = profile }
        }
        let log = LogCollector()
        let result = try await Slimmer.slim(device, profile: profile, boot: boot, log: log.append)
        return SlimOutput(
            simulator: SimulatorRef(device), profile: ProfileSummary(profile),
            disabled: result.change.disabled, reenabled: result.change.reenabled, booted: result.booted,
            verified: result.notHonoured?.isEmpty ?? false, notHonoured: result.notHonoured ?? [],
            log: log.lines)
    }

    public static func off(simulator: String, boot: Bool) async throws -> OffOutput {
        let device = try await Simctl.resolve(simulator)
        let log = LogCollector()
        let result = try await Slimmer.restore(device, boot: boot, log: log.append)
        return OffOutput(simulator: SimulatorRef(device), reenabled: result.change.reenabled,
                         alreadyStock: result.change.isEmpty, booted: result.booted, log: log.lines)
    }

    public static func measure(simulator: String) async throws -> MeasureOutput {
        let device = try await Simctl.resolve(simulator)
        let procs = try await Measure.detailed(device.udid)
        return MeasureOutput(
            simulator: SimulatorRef(device), processCount: procs.count,
            totalBytes: procs.reduce(0) { $0 + $1.bytes },
            processes: procs.map { MeasuredProcess(pid: $0.pid, name: $0.name, bytes: $0.bytes) })
    }

    public static func catalog() -> CatalogOutput {
        CatalogOutput(
            slimmableCount: ServiceCatalog.slimmable.count,
            categories: ServiceCatalog.categories.map { c in
                CatalogCategory(id: c.id, name: c.name, description: c.description, downside: c.downside,
                                approxMemoryMB: c.approxMemoryMB,
                                services: c.labels.map { CatalogService(label: $0, description: ServiceCatalog.descriptions[$0] ?? "") })
            },
            neverDisabled: NeverDisable.labels.sorted { $0.key < $1.key }.map { ProtectedService(label: $0.key, reason: $0.value) })
    }
}

/// Collects `Log` lines from a slim or restore run.
final class LogCollector: Sendable {
    private let storage = Mutex<[String]>([])
    var lines: [String] { storage.withLock { $0 } }
    var append: Log { { line in self.storage.withLock { $0.append(line) } } }
}
