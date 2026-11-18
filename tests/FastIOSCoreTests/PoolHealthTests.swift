import Foundation
import Synchronization
import Testing
@testable import FastIOSCore

@Suite("Pool health: boot timeout, retire, replace")
struct PoolHealthTests {
    static func memory(_ pressure: String, _ availableMB: Int = 8000) -> MemoryStatus {
        MemoryStatus(availableMB: availableMB, totalMB: 24576, pressure: pressure)
    }

    @Test("Boot timeout grows with memory pressure and low memory, capped at 15 min")
    func bootTimeout() {
        #expect(SimHealth.bootTimeout(memory: Self.memory("normal"), base: 120) == 120)
        #expect(SimHealth.bootTimeout(memory: Self.memory("warning"), base: 120) == 240)
        #expect(SimHealth.bootTimeout(memory: Self.memory("critical"), base: 120) == 360)
        #expect(SimHealth.bootTimeout(memory: Self.memory("normal", 1500), base: 120) == 180)
        #expect(SimHealth.bootTimeout(memory: Self.memory("critical", 500), base: 300) == 900)
    }

    @Test("Only simulators fast-ios created are deleted")
    func deleteRule() {
        #expect(SimHealth.shouldDelete(adopted: false))
        #expect(!SimHealth.shouldDelete(adopted: true))
    }

    /// A fake pool: hands out simulators in order; `broken` ones fail to boot.
    final class FakePool: Sendable {
        let broken: Set<String>
        let order: [String]
        let next = Mutex(0)
        let retired = Mutex<[String]>([])
        init(order: [String], broken: Set<String>) { self.order = order; self.broken = broken }

        func lease() throws -> String {
            let udid = next.withLock { i in defer { i += 1 }; return order[i] }
            if broken.contains(udid) {
                throw BootFailureContext(udid: udid, adopted: udid.hasPrefix("adopted"), failure: .timedOut(seconds: 180))
            }
            return udid
        }

        func retire(_ f: BootFailureContext) -> Replacement {
            retired.withLock { $0.append(f.udid) }
            return Replacement(udid: f.udid, reason: f.failure.reason, detail: f.failure.localizedDescription,
                               deleted: SimHealth.shouldDelete(adopted: f.adopted))
        }
    }

    @Test("A broken simulator is retired and the next one is leased")
    func replacesBroken() async throws {
        let pool = FakePool(order: ["sim-a", "adopted-b", "sim-c"], broken: ["sim-a", "adopted-b"])
        let (udid, replaced) = try await SimHealth.withReplacement(
            maxAttempts: 3, attempt: { _ in try pool.lease() }, retire: { pool.retire($0) })
        #expect(udid == "sim-c")
        #expect(replaced.map(\.udid) == ["sim-a", "adopted-b"])
        #expect(replaced.map(\.deleted) == [true, false])
        #expect(replaced.allSatisfy { $0.reason == "boot-timeout" })
        #expect(pool.retired.withLock { $0 } == ["sim-a", "adopted-b"])
    }

    @Test("After maxAttempts broken simulators the lease fails with every replacement")
    func exhausts() async {
        let pool = FakePool(order: ["a", "b", "c", "d"], broken: ["a", "b", "c", "d"])
        do {
            _ = try await SimHealth.withReplacement(maxAttempts: 3, attempt: { _ in try pool.lease() }, retire: { pool.retire($0) })
            Issue.record("expected PoolExhausted")
        } catch let e as PoolExhausted {
            #expect(e.replaced.map(\.udid) == ["a", "b", "c"])
            #expect(e.localizedDescription.contains("fast-ios doctor"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(pool.next.withLock { $0 } == 3)
    }

    @Test("Other errors are not retried and retire nothing")
    func otherErrorsPassThrough() async {
        let retired = Mutex(0)
        do {
            _ = try await SimHealth.withReplacement(
                maxAttempts: 3,
                attempt: { _ -> String in throw SimctlError(message: "No available iOS runtime") },
                retire: { f in retired.withLock { $0 += 1 }; return Replacement(udid: f.udid, reason: "", detail: "", deleted: false) })
            Issue.record("expected an error")
        } catch let e as SimctlError {
            #expect(e.message.contains("runtime"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(retired.withLock { $0 } == 0)
    }

    @Test("Shell.run with a timeout terminates the tool and throws ShellTimeout")
    func shellTimeout() async {
        let start = ContinuousClock.now
        do {
            _ = try await Shell.run("/bin/sleep", ["10"], timeout: 0.5)
            Issue.record("expected ShellTimeout")
        } catch let e as ShellTimeout {
            #expect(e.seconds == 0.5)
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("A boot failure maps to a stable JSON reason")
    func reasons() {
        #expect(BootFailure.timedOut(seconds: 1).reason == "boot-timeout")
        #expect(BootFailure.bootFailed("x").reason == "boot-failed")
        #expect(BootFailure.notResponding("x").reason == "not-responding")
    }
}

@Suite("Templates and pool config", .serialized)
struct TemplateStoreTests {
    @Test("Template records persist under the lock, keyed by set, runtime and device type")
    func roundTrip() throws {
        TestEnv.ready()
        let k = Templates.key(set: "/tmp/set", runtime: "rt", deviceType: "dt")
        #expect(k == "/tmp/set|rt|dt")
        try Templates.withLock { state in
            state.templates[k] = TemplateRecord(udid: "U", name: "fast-ios-template-rt-dt", deviceSet: "/tmp/set",
                                                runtime: "rt", deviceType: "dt", createdAt: Date(), ready: true,
                                                builder: nil, buildSeconds: 12.5)
        }
        let back = try Templates.withLock { $0.templates[k] }
        #expect(back?.ready == true && back?.buildSeconds == 12.5)
        #expect(Templates.list().contains { $0.udid == "U" })
        try Templates.withLock { $0.templates[k] = nil }
    }

    @Test("Pool size defaults to 1 and persists")
    func poolConfig() throws {
        TestEnv.ready()
        try? FileManager.default.removeItem(at: PoolConfig.url)
        #expect(PoolConfig.load().size == 1)
        try PoolConfig(size: 3).save()
        #expect(PoolConfig.load().size == 3)
        try FileManager.default.removeItem(at: PoolConfig.url)
    }
}
