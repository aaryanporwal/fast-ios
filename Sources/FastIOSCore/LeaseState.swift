import Foundation

/// A process, identified by pid plus start time so a reused pid is not
/// mistaken for the original owner.
public struct ProcessRef: Codable, Sendable, Hashable {
    public let pid: Int32
    public let startTime: Double
    public let name: String

    public var isAlive: Bool {
        guard let info = ProcessInfoLite.read(pid) else { return false }
        return abs(info.startTime - startTime) < 1
    }

    public static var current: ProcessRef {
        let pid = getpid()
        let info = ProcessInfoLite.read(pid)
        return ProcessRef(pid: pid, startTime: info?.startTime ?? 0, name: info?.name ?? "fast-ios")
    }

    public static func of(_ pid: Int32) -> ProcessRef? {
        ProcessInfoLite.read(pid).map { ProcessRef(pid: pid, startTime: $0.startTime, name: $0.name) }
    }
}

/// A simulator fast-ios created for leasing (or one adopted with
/// `--allow-existing`). Only these are ever leased, shut down or reslimmed.
public struct PoolDevice: Codable, Sendable, Hashable {
    public let udid: String
    public let name: String
    public let deviceSet: String
    public let runtime: String
    public let deviceType: String
    public let createdAt: Date
    /// true when the simulator existed before fast-ios leased it.
    public let adopted: Bool
    /// Being shut down by an idle trim; not leasable until that finishes.
    public var draining: Bool = false
    /// When its last lease ended; nil until then (PoolTrim uses createdAt).
    public var idleSince: Date? = nil

    public init(udid: String, name: String, deviceSet: String, runtime: String, deviceType: String, createdAt: Date,
                adopted: Bool, draining: Bool = false, idleSince: Date? = nil) {
        self.udid = udid; self.name = name; self.deviceSet = deviceSet; self.runtime = runtime
        self.deviceType = deviceType; self.createdAt = createdAt; self.adopted = adopted
        self.draining = draining; self.idleSince = idleSince
    }

    enum CodingKeys: String, CodingKey { case udid, name, deviceSet, runtime, deviceType, createdAt, adopted, draining, idleSince }

    /// Older leases.json files lack `draining` and `idleSince`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        udid = try c.decode(String.self, forKey: .udid)
        name = try c.decode(String.self, forKey: .name)
        deviceSet = try c.decode(String.self, forKey: .deviceSet)
        runtime = try c.decode(String.self, forKey: .runtime)
        deviceType = try c.decode(String.self, forKey: .deviceType)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        adopted = try c.decode(Bool.self, forKey: .adopted)
        draining = try c.decodeIfPresent(Bool.self, forKey: .draining) ?? false
        idleSince = try c.decodeIfPresent(Date.self, forKey: .idleSince)
    }
}

public struct Lease: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case preparing, ready }
    /// The simulator, or "pending-<uuid>" while fast-ios creates it.
    public var udid: String
    public let owner: String
    /// The process whose exit ends the lease.
    public let ownerProcess: ProcessRef?
    /// The fast-ios process preparing the lease; if it dies mid-boot the
    /// claim is dropped.
    public let preparer: ProcessRef
    public let deviceSet: String
    public var leasedAt: Date
    public var expiresAt: Date
    public var profileName: String
    public var status: Status
}

/// One waiting `lease` call. The queue is first come, first served.
public struct LeaseTicket: Codable, Sendable, Hashable {
    public let id: UUID
    public let process: ProcessRef
    public let owner: String
    public let enqueuedAt: Date
    /// The queue is per device set; nil in state written before this field.
    public var deviceSet: String? = nil
}

public struct LeaseState: Codable, Sendable {
    public var pool: [String: PoolDevice] = [:]
    public var leases: [String: Lease] = [:]
    public var queue: [LeaseTicket] = []
    public init() {}

    /// Drops leases whose TTL passed, whose owner exited, or whose preparing
    /// fast-ios process died; drops tickets of dead waiters. Returns the
    /// simulators that became free.
    @discardableResult
    public mutating func reap(now: Date = Date()) -> [Lease] {
        var released: [Lease] = []
        for (key, lease) in leases {
            let ownerGone = lease.ownerProcess.map { !$0.isAlive } ?? false
            let expired = lease.status == .ready && lease.expiresAt < now
            let preparerGone = lease.status == .preparing && !lease.preparer.isAlive
            if ownerGone || expired || preparerGone {
                leases[key] = nil
                pool[key]?.idleSince = now
                released.append(lease)
            }
        }
        queue.removeAll { !$0.process.isAlive }
        return released
    }
}

public struct LeaseStoreError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// leases.json beside state.json, guarded by flock(2) on leases.lock so
/// several agents can call fast-ios at once. The lock is held only while
/// reading, deciding and writing, never across a boot.
public enum LeaseStore {
    static var folder: URL { StateStore.url.deletingLastPathComponent() }
    public static var fileURL: URL { folder.appendingPathComponent("leases.json") }
    static var lockURL: URL { folder.appendingPathComponent("leases.lock") }

    public static func withLock<T>(_ body: (inout LeaseState) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw LeaseStoreError(message: "Cannot open \(lockURL.path): errno \(errno)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw LeaseStoreError(message: "Cannot lock \(lockURL.path): errno \(errno)") }
        defer { flock(fd, LOCK_UN) }
        var state = load()
        let result = try body(&state)
        try save(state)
        return result
    }

    static func load() -> LeaseState {
        guard let data = try? Data(contentsOf: fileURL) else { return LeaseState() }
        return (try? decoder.decode(LeaseState.self, from: data)) ?? LeaseState()
    }

    static func save(_ state: LeaseState) throws {
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
