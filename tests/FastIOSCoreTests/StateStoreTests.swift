import Foundation
import Testing
@testable import FastIOSCore

// Serialized: these tests share state.json in the test state folder.
@Suite("Profile save and load", .serialized)
struct StateStoreTests {
    @Test("record then load returns the profile applied to each simulator")
    func recordRoundTrip() throws {
        TestEnv.ready()
        let udid = UUID().uuidString
        let profile = Profiler.full(keeping: ["com.apple.healthd"])
        try StateStore.record(udid, profile: profile)
        let rec = try #require(StateStore.load().devices[udid])
        #expect(rec.profileName == "full")
        #expect(rec.disabledCount == profile.disable.count)
        #expect(abs(rec.updatedAt.timeIntervalSinceNow) < 60)
    }

    @Test("The default profile survives a save and load unchanged")
    func defaultProfileRoundTrip() throws {
        TestEnv.ready()
        let facts = AppFacts(appPath: "/tmp/P.app", bundleIdentifier: "dev.fastios.p",
                             infoPlistKeys: ["NSPhotoLibraryUsageDescription"], backgroundModes: ["remote-notification"],
                             entitlements: [], frameworks: [], extensionPoints: [])
        let profile = Profiler.derive(from: facts).profile
        try StateStore.update { $0.defaultProfile = profile }
        #expect(StateStore.load().defaultProfile == profile)
    }

    @Test("update keeps records it did not change")
    func updatePreservesOthers() throws {
        TestEnv.ready()
        let a = UUID().uuidString, b = UUID().uuidString
        try StateStore.record(a, profile: Profiler.full())
        try StateStore.record(b, profile: Profiler.full())
        try StateStore.update { $0.devices[a] = nil }
        let state = StateStore.load()
        #expect(state.devices[a] == nil)
        #expect(state.devices[b] != nil)
    }

    @Test("A corrupt state file loads as empty state instead of crashing")
    func corruptFile() throws {
        TestEnv.ready()
        let saved = try? Data(contentsOf: StateStore.url)
        defer { if let saved { try? saved.write(to: StateStore.url) } }
        try Data("{not json".utf8).write(to: StateStore.url)
        let state = StateStore.load()
        #expect(state.devices.isEmpty)
        #expect(state.defaultProfile == nil)
    }
}
