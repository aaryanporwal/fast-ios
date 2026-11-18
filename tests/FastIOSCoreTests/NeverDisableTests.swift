import Foundation
import Testing
@testable import FastIOSCore

@Suite("Never-disable list always wins")
struct NeverDisableTests {
    static let protected = Set(NeverDisable.labels.keys)

    @Test("No protected label is slimmable, even if a catalog category lists it")
    func notSlimmable() {
        #expect(ServiceCatalog.slimmable.isDisjoint(with: Self.protected))
        // Managed (so a stale override can be lifted), but never disabled.
        #expect(ServiceCatalog.managed.isSuperset(of: Self.protected))
    }

    @Test("No profile disables a protected label, whatever is asked")
    func profilesNeverDisable() {
        TestEnv.ready()
        #expect(Set(Profiler.full().disable).isDisjoint(with: Self.protected))
        let forced = Profiler.build(name: "custom", appPath: nil, keep: [:])
        #expect(Set(forced.disable).isDisjoint(with: Self.protected))
    }

    @Test("apply refuses to write a protected label, and lifts one an older tool left")
    func storeNeverDisables() throws {
        let udid = TestEnv.fakeUDID()
        defer { TestEnv.cleanUp(udid) }
        try DisabledStore.write(udid, ["com.apple.backboardd": true])
        let change = try DisabledStore.apply(udid, disable: Self.protected.union(["com.apple.assetsd"]))
        #expect(change.disabled == ["com.apple.assetsd"])
        #expect(change.reenabled == ["com.apple.backboardd"])
        #expect(DisabledStore.disabledLabels(udid).isDisjoint(with: Self.protected))
    }

    @Test("heal never acts on a protected label, and does not even read the store")
    func healIgnoresProtected() {
        var decider = HealDecider(cooldown: 30, maxRepairs: 10)
        let map = ServiceMap(labelForMach: ["com.apple.gamed": "com.apple.gamed"], plistForLabel: [:])
        let f = Healer.Failure(process: "App", machService: "com.apple.gamed", line: "l")
        var read = false
        let d = decider.decide(f, map: map, disabled: { read = true; return ["com.apple.gamed"] }, now: Date())
        #expect(d == .silent)
        #expect(!read)
        #expect(decider.repairs == 0)
    }
}
