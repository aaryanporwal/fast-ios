import Foundation
import Testing
@testable import FastIOSCore

@Suite("Pool trim: free pool simulators are shut down when not worth their memory")
struct PoolTrimTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let normal = MemoryStatus(availableMB: 12_000, totalMB: 24_576, pressure: "normal")
    static let warning = MemoryStatus(availableMB: 4_700, totalMB: 24_576, pressure: "warning")
    static let lowFree = MemoryStatus(availableMB: 3_000, totalMB: 24_576, pressure: "normal")
    static let policy = AdmissionPolicy(needMB: 1500, reserveMB: 2048, maxPressure: "normal")

    static func dev(_ udid: String, freeMinutes: Double, set: String = "S", adopted: Bool = false,
                    draining: Bool = false, released: Bool = true) -> PoolDevice {
        let t = now.addingTimeInterval(-freeMinutes * 60)
        return PoolDevice(udid: udid, name: "pool-\(udid)", deviceSet: set, runtime: "r", deviceType: "d",
                          createdAt: released ? now.addingTimeInterval(-86_400) : t, adopted: adopted,
                          draining: draining, idleSince: released ? t : nil)
    }

    static func decide(_ pool: [PoolDevice], leased: Set<String> = [], booted: Set<String>? = nil,
                       memory: MemoryStatus = normal, warm: Int = 1, idle: TimeInterval = 1800) -> [PoolTrim.Decision] {
        PoolTrim.decide(pool: pool, leased: leased, booted: booted ?? Set(pool.map(\.udid)), set: "S",
                        memory: memory, policy: policy, warmSize: warm, idleLimit: idle, now: now)
    }

    @Test("Under memory pressure every free pool simulator goes, oldest free first")
    func memoryPressure() {
        let pool = [Self.dev("new", freeMinutes: 1), Self.dev("old", freeMinutes: 20)]
        #expect(Self.decide(pool, memory: Self.warning) == [.init(udid: "old", reason: .memory), .init(udid: "new", reason: .memory)])
        // Normal pressure but less free memory than a new simulator needs counts too.
        #expect(Self.decide(pool, memory: Self.lowFree).map(\.reason) == [.memory, .memory])
    }

    @Test("Never a leased one, one fast-ios did not create, one stopping, one stopped, or one in another set")
    func neverTouched() {
        let pool = [Self.dev("leased", freeMinutes: 99), Self.dev("adopted", freeMinutes: 99, adopted: true),
                    Self.dev("draining", freeMinutes: 99, draining: true), Self.dev("stopped", freeMinutes: 99),
                    Self.dev("other", freeMinutes: 99, set: "T")]
        let booted: Set<String> = ["leased", "adopted", "draining", "other"]
        #expect(Self.decide(pool, leased: ["leased"], booted: booted, memory: Self.warning).isEmpty)
        #expect(Self.decide(pool, leased: ["leased"], booted: booted, memory: Self.normal, warm: 0, idle: 60).isEmpty)
    }

    @Test("With memory to spare: free past the idle limit goes, the newest within the warm size stays")
    func idleAndWarmSize() {
        let pool = [Self.dev("a", freeMinutes: 45), Self.dev("b", freeMinutes: 10), Self.dev("c", freeMinutes: 2)]
        #expect(Self.decide(pool, warm: 1) == [.init(udid: "a", reason: .idle), .init(udid: "b", reason: .overSize)])
        #expect(Self.decide(pool, warm: 2) == [.init(udid: "a", reason: .idle)])
        #expect(Self.decide(pool, warm: 0).map(\.udid) == ["a", "b", "c"])
        #expect(Self.decide([Self.dev("c", freeMinutes: 2)], warm: 1).isEmpty)
    }

    @Test("A pool simulator never leased counts as free since it was created")
    func neverLeased() {
        let d = Self.dev("fresh", freeMinutes: 40, released: false)
        #expect(d.idleSince == nil)
        #expect(Self.decide([d], warm: 1) == [.init(udid: "fresh", reason: .idle)])
    }

    @Test("Releasing and reaping a lease mark when the simulator became free")
    func idleSinceOnRelease() {
        var state = LeaseState()
        state.pool["P"] = Self.dev("P", freeMinutes: 0, released: false)
        state.leases["P"] = Lease(udid: "P", owner: "t", ownerProcess: nil, preparer: .current, deviceSet: "S",
                                  leasedAt: Self.now, expiresAt: Self.now.addingTimeInterval(-1), profileName: "x", status: .ready)
        let later = Self.now.addingTimeInterval(60)
        #expect(state.reap(now: later).count == 1)
        #expect(state.pool["P"]?.idleSince == later)
    }

    @Test("An older leases.json without the new fields still loads")
    func oldStateLoads() throws {
        let json = #"{"udid":"P","name":"n","deviceSet":"","runtime":"r","deviceType":"d","createdAt":"2026-11-17T00:00:00Z","adopted":false}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let p = try d.decode(PoolDevice.self, from: Data(json.utf8))
        #expect(!p.draining && p.idleSince == nil)
    }

    @Test("The pool description says what each one does and what happens next")
    func describe() {
        let pool = [Self.dev("warm", freeMinutes: 5), Self.dev("leased", freeMinutes: 5), Self.dev("off", freeMinutes: 5)]
        let lines = PoolTrim.describe(pool: pool, leased: ["leased"], booted: ["warm", "leased"], set: "S",
                                      memory: Self.normal, policy: Self.policy, warmSize: 1, idleLimit: 1800, now: Self.now)
        #expect(lines.contains { $0.hasPrefix("pool-warm: running, free 5 min, kept warm") && $0.contains("stops in 25 min") })
        #expect(lines.contains("pool-leased: leased."))
        #expect(lines.contains { $0.hasPrefix("pool-off: stopped") })
        let short = PoolTrim.describe(pool: pool, leased: ["leased"], booted: ["warm", "leased"], set: "S",
                                      memory: Self.warning, policy: Self.policy, warmSize: 1, idleLimit: 1800, now: Self.now)
        #expect(short.contains { $0.hasPrefix("pool-warm") && $0.contains("stops now: memory is short (warning") })
    }
}
