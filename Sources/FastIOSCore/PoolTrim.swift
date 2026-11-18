import Foundation

/// Which free pool simulators to shut down, and why. A warm simulator is only
/// worth its memory while the Mac has memory to spare and someone may lease it
/// soon. Pure, so the rule is tested without simulators.
///
/// Only simulators fast-ios created are touched: never an adopted one
/// (`--allow-existing`), never a leased one, never one already stopping.
public enum PoolTrim {
    public enum Reason: String, Sendable, Codable, Equatable {
        /// Memory pressure is not normal, or free memory is below what a new
        /// simulator needs: free ones go, oldest first, until memory is back.
        case memory
        /// Free for longer than the idle limit.
        case idle
        /// More free ones than the warm size (`fast-ios pool --size`).
        case overSize = "over-size"
    }

    public struct Decision: Sendable, Equatable, Codable {
        public let udid: String
        public let reason: Reason
        public init(udid: String, reason: Reason) { self.udid = udid; self.reason = reason }
    }

    /// When a free simulator last became free: the release time, else when it
    /// was created.
    public static func freeSince(_ d: PoolDevice) -> Date { d.idleSince ?? d.createdAt }

    /// Free pool simulators of `set` that may be shut down: created by
    /// fast-ios, running, not leased, not already stopping. Oldest free first.
    public static func candidates(pool: [PoolDevice], leased: Set<String>, booted: Set<String>, set: String) -> [PoolDevice] {
        pool.filter { $0.deviceSet == set && !$0.adopted && !$0.draining && !leased.contains($0.udid) && booted.contains($0.udid) }
            .sorted { freeSince($0) < freeSince($1) }
    }

    public static func decide(pool: [PoolDevice], leased: Set<String>, booted: Set<String>, set: String,
                              memory: MemoryStatus, policy: AdmissionPolicy, warmSize: Int,
                              idleLimit: TimeInterval, now: Date = Date()) -> [Decision] {
        let free = candidates(pool: pool, leased: leased, booted: booted, set: set)
        // Short of memory: no warm simulator is worth keeping.
        if !policy.admits(memory, pendingBoots: 0) {
            return free.map { Decision(udid: $0.udid, reason: .memory) }
        }
        var out: [Decision] = []
        var kept: [PoolDevice] = []
        for d in free {
            if now.timeIntervalSince(freeSince(d)) >= idleLimit {
                out.append(Decision(udid: d.udid, reason: .idle))
            } else {
                kept.append(d)
            }
        }
        // Keep the newest `warmSize`; the oldest beyond that go.
        let extra = max(0, kept.count - max(0, warmSize))
        out += kept.prefix(extra).map { Decision(udid: $0.udid, reason: .overSize) }
        return out
    }

    /// The idle limit: FASTIOS_POOL_IDLE (such as "30m"), else
    /// `fast-ios pool --idle`, else 30 minutes.
    public static var idleLimit: TimeInterval {
        if let s = ProcessInfo.processInfo.environment["FASTIOS_POOL_IDLE"], let t = FastIOSCommands.parseDuration(s) { return t }
        return PoolConfig.load().idleMinutes.map { TimeInterval($0) * 60 } ?? 30 * 60
    }

    /// One line per pool simulator of this set, for `fast-ios` and `leases`:
    /// what it is doing and what happens to it next.
    public static func describe(pool: [PoolDevice], leased: Set<String>, booted: Set<String>, set: String,
                                memory: MemoryStatus, policy: AdmissionPolicy, warmSize: Int,
                                idleLimit: TimeInterval, now: Date = Date()) -> [String] {
        let mine = pool.filter { $0.deviceSet == set }.sorted { $0.createdAt < $1.createdAt }
        guard !mine.isEmpty else { return [] }
        let decisions = Dictionary(decide(pool: pool, leased: leased, booted: booted, set: set, memory: memory, policy: policy,
                                          warmSize: warmSize, idleLimit: idleLimit, now: now).map { ($0.udid, $0.reason) },
                                   uniquingKeysWith: { a, _ in a })
        return mine.map { d in
            let name = d.name
            if leased.contains(d.udid) { return "\(name): leased." }
            if !booted.contains(d.udid) { return "\(name): stopped, free (uses no memory)." }
            if d.adopted { return "\(name): running, free; fast-ios did not create it, so it never stops it." }
            if d.draining { return "\(name): stopping." }
            let idle = Int(now.timeIntervalSince(freeSince(d)) / 60)
            switch decisions[d.udid] {
            case .memory?: return "\(name): running, free \(idle) min; stops now: memory is short (\(memory.pressure), \(memory.availableMB) MB free)."
            case .idle?: return "\(name): running, free \(idle) min; stops now: free longer than \(Int(idleLimit / 60)) min."
            case .overSize?: return "\(name): running, free \(idle) min; stops now: more than \(warmSize) kept warm."
            case nil:
                let left = max(0, Int((idleLimit - now.timeIntervalSince(freeSince(d))) / 60))
                return "\(name): running, free \(idle) min, kept warm for the next run; stops in \(left) min, or at once if memory gets short."
            }
        }
    }
}
