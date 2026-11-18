import Foundation

/// How many free, booted pool simulators to keep warm (`fast-ios pool --size`).
/// LeaseManager.trimIdle reads it; 1 when never set.
public struct PoolConfig: Codable, Sendable {
    public var size: Int = 1
    /// Minutes a free, running pool simulator is kept before it is shut down
    /// (`fast-ios pool --idle`); nil means 30.
    public var idleMinutes: Int?

    public init(size: Int = 1, idleMinutes: Int? = nil) { self.size = size; self.idleMinutes = idleMinutes }

    static var url: URL { StateStore.url.deletingLastPathComponent().appendingPathComponent("pool.json") }

    public static func load() -> PoolConfig {
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(PoolConfig.self, from: data) else { return PoolConfig() }
        return c
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}

public struct PoolOutput: Encodable, Sendable {
    public var schemaVersion = JSONOutput.schemaVersion
    /// The warm size now in force.
    public let size: Int
    /// Free booted pool simulators of this device set after the call.
    public let free: [String]
    /// Simulators this call booted (created or started).
    public let booted: [String]
    /// Why the pool is short of `size`, or null when it is full.
    @EncodeNull public var shortBecause: String?
    public let memory: MemoryStatus
    public let log: [String]
}

/// Keeps `size` slim simulators booted and free, so the next `run` or `lease`
/// only installs and launches. Uses LeaseManager for every boot, so the same
/// memory admission applies: a boot that would overcommit memory is not made.
public enum Pool {
    public static func set(size: Int, profile: SlimProfile, runtime: String?, deviceType: String?,
                           policy: AdmissionPolicy, timeout: TimeInterval, idleMinutes: Int? = nil,
                           log: @escaping Log = { _ in }) async throws -> PoolOutput {
        let collected = LogCollector()
        let both: Log = { collected.append($0); log($0) }
        var config = PoolConfig.load()
        config.size = size
        if let idleMinutes { config.idleMinutes = idleMinutes }
        try config.save()

        var held: [String] = []
        var booted: [String] = []
        var short: String?
        // Hold leases until `size` are in hand: a free booted simulator would
        // otherwise be handed back by every lease call.
        for _ in 0..<max(0, size) {
            var req = LeaseRequest(profile: profile)
            req.runtime = runtime; req.deviceType = deviceType
            req.policy = policy; req.timeout = timeout
            req.owner = "fast-ios pool"; req.ownerPid = getpid(); req.ttl = 600
            do {
                let r = try await LeaseManager.lease(req, log: both)
                held.append(r.udid)
                if r.source != .reusedBooted { booted.append(r.udid) }
            } catch let refusal as LeaseRefusal {
                short = refusal.detail
                both("stopping at \(held.count) of \(size): \(refusal.detail)")
                break
            }
        }
        for udid in held { _ = try? await LeaseManager.release(udid, log: both) }
        await LeaseManager.trimIdle(log: both)

        let listing = try await LeaseManager.list()
        let devices = try await Simctl.listDevices()
        let bootedNow = Set(devices.filter(\.isBooted).map(\.udid))
        let set = Simctl.deviceSet ?? ""
        let leased = Set(listing.leases.map(\.udid))
        let free = listing.pool.filter { $0.deviceSet == set && bootedNow.contains($0.udid) && !leased.contains($0.udid) }.map(\.udid)
        return PoolOutput(size: size, free: free, booted: booted, shortBecause: short, memory: MemoryStatus.read(), log: collected.lines)
    }
}
