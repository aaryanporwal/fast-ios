import Foundation
import Synchronization

/// A pool simulator that failed to become usable.
public enum BootFailure: Error, Sendable, Equatable, LocalizedError {
    /// `bootstatus` did not finish within the timeout.
    case timedOut(seconds: Int)
    /// `simctl boot`/`bootstatus` exited with an error.
    case bootFailed(String)
    /// Booted, but launchd inside it did not answer.
    case notResponding(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let s): "did not finish booting within \(s) s"
        case .bootFailed(let m): "failed to boot: \(m)"
        case .notResponding(let m): "booted but launchd did not answer: \(m)"
        }
    }

    /// Short machine-readable reason for JSON.
    public var reason: String {
        switch self {
        case .timedOut: "boot-timeout"
        case .bootFailed: "boot-failed"
        case .notResponding: "not-responding"
        }
    }
}

/// One simulator a lease gave up on and what was done with it.
public struct Replacement: Codable, Sendable, Hashable {
    public let udid: String
    /// "boot-timeout", "boot-failed" or "not-responding".
    public let reason: String
    public let detail: String
    /// True when fast-ios deleted it (it created it); false when it was only
    /// shut down and dropped from the pool (it existed before fast-ios).
    public let deleted: Bool
}

/// The pool's rules for slow and broken simulators. Pure functions, so the
/// tests can drive them with fakes.
public enum SimHealth {
    /// Boot timeout for one simulator: `base` when memory is fine, longer
    /// when the Mac is paging, since a fixed deadline fails on busy Macs.
    /// `FASTIOS_BOOT_TIMEOUT` (seconds) replaces `base`.
    public static func bootTimeout(memory: MemoryStatus, base: TimeInterval = defaultBase) -> TimeInterval {
        var t = base
        switch memory.pressure {
        case "critical": t *= 3
        case "warning": t *= 2
        default: break
        }
        // Less than 2 GB available: boots page; allow another half.
        if memory.availableMB < 2048 { t *= 1.5 }
        return min(t, 900)
    }

    public static var defaultBase: TimeInterval {
        ProcessInfo.processInfo.environment["FASTIOS_BOOT_TIMEOUT"].flatMap(Double.init) ?? 180
    }

    /// Whether to delete a failed simulator. Only simulators fast-ios
    /// created are deleted; one that existed before (`adopted`) is shut
    /// down and dropped from the pool, never deleted.
    public static func shouldDelete(adopted: Bool) -> Bool { !adopted }

    /// Runs `attempt` up to `maxAttempts` times. A BootFailure calls
    /// `retire` (which removes that simulator) and tries again; any other
    /// error is thrown at once. Returns the result and every replacement.
    public static func withReplacement<T: Sendable>(
        maxAttempts: Int,
        attempt: (Int) async throws -> T,
        retire: (BootFailureContext) async -> Replacement
    ) async throws -> (T, [Replacement]) {
        var replaced: [Replacement] = []
        var n = 0
        while true {
            n += 1
            do {
                return (try await attempt(n), replaced)
            } catch let failed as BootFailureContext {
                replaced.append(await retire(failed))
                if n >= maxAttempts {
                    throw PoolExhausted(replaced: replaced)
                }
            }
        }
    }
}

/// A BootFailure with the simulator it happened on.
public struct BootFailureContext: Error, Sendable, LocalizedError {
    public let udid: String
    public let adopted: Bool
    public let failure: BootFailure
    public init(udid: String, adopted: Bool, failure: BootFailure) {
        self.udid = udid; self.adopted = adopted; self.failure = failure
    }
    public var errorDescription: String? { "Simulator \(udid) \(failure.localizedDescription)" }
}

/// Every attempt hit a broken simulator.
public struct PoolExhausted: Error, Sendable, LocalizedError {
    public let replaced: [Replacement]
    public var errorDescription: String? {
        "\(replaced.count) simulator(s) in a row failed to boot (\(replaced.map(\.reason).joined(separator: ", "))). "
            + "Run `fast-ios doctor`; if the runtime is broken, `xcodebuild -downloadPlatform iOS` reinstalls it."
    }
}

/// Makes `FASTIOS_INJECT_BOOT_TIMEOUT` fire once per process.
enum FaultOnce {
    static let used = AtomicFlag()
}

/// A flag that flips from false to true once.
final class AtomicFlag: Sendable {
    private let value = Mutex(false)
    /// Sets the flag; returns what it was before.
    func swap() -> Bool { value.withLock { old in defer { old = true }; return old } }
}

extension MCPTools {
    /// JSON Schema for a `replaced` array of Replacement.
    static let replacedSchema = Schema.array(Schema.object([
        "udid": Schema.string(), "reason": Schema.string("boot-timeout, boot-failed or not-responding"),
        "detail": Schema.string(), "deleted": Schema.boolean("Deleted because fast-ios created it; else only dropped from the pool."),
    ], required: ["udid", "reason", "detail", "deleted"]),
        "Simulators that failed to boot or answer and were retired before this one.")
}

/// Samples memory once a second until cancelled (bench parallel rounds).
actor MemorySampler {
    private var minMB = Int.max
    private var worst = "normal"

    func run() async {
        while !Task.isCancelled {
            record(MemoryStatus.read())
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func record(_ m: MemoryStatus) {
        minMB = min(minMB, m.availableMB)
        let rank = ["normal": 0, "warning": 1, "critical": 2]
        if (rank[m.pressure] ?? 0) > (rank[worst] ?? 0) { worst = m.pressure }
    }

    func result() -> (Int, String) {
        record(MemoryStatus.read())
        return (minMB, worst)
    }
}
