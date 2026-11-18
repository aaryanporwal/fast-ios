import Foundation

public typealias Log = @Sendable (String) -> Void

public struct SlimResult: Sendable {
    public let change: DisabledStore.Change
    public let booted: Bool
    /// Labels the booted simulator still does not report as disabled. Empty
    /// when verified, nil when the simulator was left shut down.
    public let notHonoured: [String]?
}

public enum Slimmer {
    /// Applies a profile: shuts the simulator down if it is running, writes the
    /// disable overrides, and boots it again if it was running (or `boot`).
    /// A shut-down simulator boots slim the next time anything boots it.
    public static func slim(_ device: SimDevice, profile: SlimProfile, boot: Bool = false, log: Log = { _ in }) async throws -> SlimResult {
        let result = try await apply(device, disable: profile.disableSet, boot: boot, log: log)
        try StateStore.record(device.udid, profile: profile)
        return result
    }

    /// Restores stock: removes every override fast-ios manages.
    public static func restore(_ device: SimDevice, boot: Bool = false, log: Log = { _ in }) async throws -> SlimResult {
        let result = try await apply(device, disable: [], boot: boot, log: log)
        try StateStore.update { $0.devices[device.udid] = nil }
        return result
    }

    static func apply(_ device: SimDevice, disable: Set<String>, boot: Bool, log: Log) async throws -> SlimResult {
        let wasBooted = device.isBooted
        let pending = try pendingChange(device.udid, disable: disable)
        if wasBooted && pending {
            log("Restarting \(device.name) so the change takes effect…")
            try await Simctl.shutdownAndWait(device.udid)
        }
        // A booted device with nothing to change is left running.
        let change = (wasBooted && !pending) ? DisabledStore.Change(disabled: [], reenabled: [])
                                             : try DisabledStore.apply(device.udid, disable: disable)
        if !change.isEmpty {
            log("Wrote \(change.disabled.count) disables and \(change.reenabled.count) re-enables to \(DisabledStore.path(device.udid).path)")
        }
        guard wasBooted || boot else {
            return SlimResult(change: change, booted: false, notHonoured: nil)
        }
        if pending || !wasBooted {
            log("Starting \(device.name)…")
            try await Simctl.bootAndWait(device.udid)
        }
        var missing = try await notHonoured(device.udid, disable: disable)
        if !missing.isEmpty {
            // The store is an undocumented CoreSimulator detail. If this runtime
            // ignored it, take the supported route: launchctl disable, reboot.
            log("Restarting \(device.name) once more: \(missing.count) services were still on after the first start, so fast-ios turns them off another way…")
            for label in missing { try await Simctl.launchctlDisable(device.udid, label: label) }
            try await Simctl.shutdownAndWait(device.udid)
            try await Simctl.bootAndWait(device.udid)
            missing = try await notHonoured(device.udid, disable: disable)
        }
        return SlimResult(change: change, booted: true, notHonoured: missing)
    }

    static func pendingChange(_ udid: String, disable: Set<String>) throws -> Bool {
        let entries = try DisabledStore.read(udid)
        let safe = disable.intersection(ServiceCatalog.managed).filter { !NeverDisable.isProtected($0) }
        if safe.contains(where: { entries[$0] != true }) { return true }
        return entries.contains { $0.value && ServiceCatalog.managed.contains($0.key) && !safe.contains($0.key) }
    }

    static func notHonoured(_ udid: String, disable: Set<String>) async throws -> [String] {
        let live = try await Simctl.printDisabled(udid)
        let safe = disable.filter { !NeverDisable.isProtected($0) }
        return safe.subtracting(live).sorted()
    }
}
