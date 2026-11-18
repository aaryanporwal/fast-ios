import Foundation

/// Simulators that were running when `fast-ios on` ran. Their overrides can
/// only be written while they are stopped (a running launchd_sim keeps its
/// own copy), so the helper makes each one light as soon as it stops, before
/// it can start again. Kept in pending-light.json beside state.json.
public enum PendingLight {
    static var url: URL { StateStore.url.deletingLastPathComponent().appendingPathComponent("pending-light.json") }

    public static func load() -> Set<String> {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    static func save(_ set: Set<String>) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if set.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try JSONEncoder().encode(set.sorted()).write(to: url, options: .atomic)
        }
    }

    public static func add(_ udids: [String]) throws {
        guard !udids.isEmpty else { return }
        try save(load().union(udids))
    }

    public static func clear() { try? save([]) }

    /// One pass: every pending simulator that is stopped now gets the general
    /// profile; one that no longer exists is forgotten. Returns the UDIDs made
    /// light.
    @discardableResult
    public static func applyStopped(devices: [SimDevice], profile: SlimProfile, log: (String) -> Void) -> [String] {
        let pending = load()
        guard !pending.isEmpty else { return [] }
        let byUDID = Dictionary(devices.map { ($0.udid, $0) }, uniquingKeysWith: { a, _ in a })
        var remaining = pending
        var made: [String] = []
        for udid in pending {
            guard let d = byUDID[udid] else { remaining.remove(udid); continue }
            guard d.state == "Shutdown" else { continue }
            do {
                let change = try DisabledStore.apply(udid, disable: profile.disableSet)
                try StateStore.record(udid, profile: profile)
                remaining.remove(udid)
                made.append(udid)
                log("\(udid): stopped, made light before its next start (\(change.disabled.count) services off)")
            } catch {
                log("\(udid): could not make it light: \(error.localizedDescription)")
            }
        }
        try? save(remaining)
        return made
    }
}
