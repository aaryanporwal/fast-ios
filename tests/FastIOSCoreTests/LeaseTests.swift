import Foundation
import Testing
@testable import FastIOSCore

// Serialized: these tests share leases.json in the test state folder.
@Suite("Lease state", .serialized)
struct LeaseTests {
    static func lease(_ udid: String, owner: ProcessRef?, status: Lease.Status = .ready,
                      expiresIn: TimeInterval = 600, preparer: ProcessRef = .current) -> Lease {
        Lease(udid: udid, owner: "test", ownerProcess: owner, preparer: preparer, deviceSet: "default",
              leasedAt: Date(), expiresAt: Date().addingTimeInterval(expiresIn), profileName: "full", status: status)
    }

    /// A process that is running now and can be killed on demand.
    static func spawnSleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        try p.run()
        return p
    }

    @Test("Parallel withLock calls never lose an update")
    func concurrentAccess() async throws {
        TestEnv.ready()
        try LeaseStore.withLock { $0 = LeaseState() }
        let me = ProcessRef.current
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<48 {
                group.addTask {
                    _ = try? LeaseStore.withLock { state in
                        state.queue.append(LeaseTicket(id: UUID(), process: me, owner: "t\(i)", enqueuedAt: Date()))
                    }
                }
            }
        }
        let count = try LeaseStore.withLock { $0.queue.count }
        #expect(count == 48)
        try LeaseStore.withLock { $0 = LeaseState() }
    }

    @Test("A lease ends when its owner process exits")
    func ownerExitReleases() throws {
        let sleeper = try Self.spawnSleeper()
        let owner = try #require(ProcessRef.of(sleeper.processIdentifier))
        var state = LeaseState()
        state.leases["A"] = Self.lease("A", owner: owner)
        #expect(state.reap().isEmpty, "a live owner keeps the lease")
        sleeper.terminate()
        sleeper.waitUntilExit()
        let released = state.reap()
        #expect(released.map(\.udid) == ["A"])
        #expect(state.leases.isEmpty)
    }

    @Test("A reused pid with a different start time is not the owner")
    func pidReuseIsNotAlive() {
        let me = ProcessRef.current
        #expect(me.isAlive)
        #expect(!ProcessRef(pid: me.pid, startTime: me.startTime - 1000, name: me.name).isAlive)
    }

    @Test("Expired and orphaned leases are reaped; healthy ones stay")
    func reapRules() throws {
        let sleeper = try Self.spawnSleeper()
        let deadRef = try #require(ProcessRef.of(sleeper.processIdentifier))
        sleeper.terminate(); sleeper.waitUntilExit()

        var state = LeaseState()
        state.leases["expired"] = Self.lease("expired", owner: nil, expiresIn: -1)
        state.leases["preparing-orphan"] = Self.lease("preparing-orphan", owner: nil, status: .preparing, preparer: deadRef)
        state.leases["preparing-live"] = Self.lease("preparing-live", owner: nil, status: .preparing, expiresIn: -1)
        state.leases["healthy"] = Self.lease("healthy", owner: .current)
        state.queue = [LeaseTicket(id: UUID(), process: deadRef, owner: "gone", enqueuedAt: Date()),
                       LeaseTicket(id: UUID(), process: .current, owner: "me", enqueuedAt: Date())]

        let released = Set(state.reap().map(\.udid))
        #expect(released == ["expired", "preparing-orphan"])
        #expect(Set(state.leases.keys) == ["preparing-live", "healthy"],
                "a preparing lease is not expired by TTL while its preparer lives")
        #expect(state.queue.map(\.owner) == ["me"])
    }

    @Test("release ends the lease once, and reports whether there was one")
    func releaseRemovesLease() async throws {
        TestEnv.ready()
        try LeaseStore.withLock { state in
            state = LeaseState()
            state.leases["SIM-1"] = Self.lease("SIM-1", owner: .current)
        }
        #expect(try await LeaseManager.release("SIM-1"))
        #expect(try LeaseStore.withLock { $0.leases["SIM-1"] } == nil)
        #expect(try await LeaseManager.release("SIM-1") == false)
    }

    @Test("Lease state survives a save and load")
    func persistence() throws {
        TestEnv.ready()
        let device = PoolDevice(udid: "P1", name: "pool-1", deviceSet: "default", runtime: "iOS-27-0",
                                deviceType: "iPhone-18-Pro", createdAt: Date(timeIntervalSince1970: 1_800_000_000), adopted: false)
        try LeaseStore.withLock { state in
            state = LeaseState()
            state.pool["P1"] = device
        }
        #expect(LeaseStore.load().pool["P1"] == device)
        try LeaseStore.withLock { $0 = LeaseState() }
    }

    @Test("Admission counts pending boots and respects memory pressure")
    func admission() {
        let policy = AdmissionPolicy(needMB: 1500, reserveMB: 2000, maxPressure: "normal")
        let roomy = MemoryStatus(availableMB: 8000, totalMB: 24000, pressure: "normal")
        #expect(policy.admits(roomy, pendingBoots: 0))
        #expect(policy.admits(roomy, pendingBoots: 3))
        #expect(!policy.admits(roomy, pendingBoots: 4), "8000 - 4*1500 - 1500 < 2000")
        #expect(!policy.admits(MemoryStatus(availableMB: 8000, totalMB: 24000, pressure: "warning"), pendingBoots: 0))
        let lenient = AdmissionPolicy(needMB: 1500, reserveMB: 2000, maxPressure: "warning")
        #expect(lenient.admits(MemoryStatus(availableMB: 8000, totalMB: 24000, pressure: "warning"), pendingBoots: 0))
        #expect(!lenient.admits(MemoryStatus(availableMB: 8000, totalMB: 24000, pressure: "critical"), pendingBoots: 0))
    }
}
