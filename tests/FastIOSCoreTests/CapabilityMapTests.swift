import Foundation
import Testing
@testable import FastIOSCore

@Suite("Capability map: which services an app keeps, and why")
struct CapabilityMapTests {
    @Test("Info.plist keys, background modes and app extensions keep their services")
    func sampleAppKeepsDeclaredServices() async throws {
        TestEnv.ready()
        let facts = try await AppInspector.inspect(TestEnv.fixture("Sample.app"))
        #expect(facts.bundleIdentifier == "dev.fastios.sample")
        #expect(facts.extensionPoints == ["com.apple.widgetkit-extension"])

        let (profile, matches) = Profiler.derive(from: facts)
        for label in ["com.apple.assetsd", "com.apple.contactsd", "com.apple.apsd", "com.apple.chronod"] {
            #expect(profile.keep[label] != nil, "\(label) should be kept")
            #expect(!profile.disable.contains(label), "\(label) must not be disabled")
        }
        #expect(profile.keep["com.apple.assetsd"]?.contains { $0.contains("NSPhotoLibraryUsageDescription") } == true)
        #expect(profile.keep["com.apple.apsd"]?.contains { $0.contains("UIBackgroundModes remote-notification") } == true)
        #expect(profile.keep["com.apple.chronod"]?.contains { $0.contains("widgetkit-extension") } == true)
        #expect(matches.contains { $0.trigger == .infoPlistKey("NSContactsUsageDescription") })
        // Unrelated features stay off.
        #expect(profile.disable.contains("com.apple.healthd"))
        #expect(profile.name == "auto: Sample.app")
    }

    @Test("An app that declares nothing disables the whole catalog")
    func plainAppDisablesEverything() async throws {
        TestEnv.ready()
        let facts = try await AppInspector.inspect(TestEnv.fixture("Plain.app"))
        let (profile, matches) = Profiler.derive(from: facts)
        #expect(matches.isEmpty)
        #expect(profile.keep.isEmpty)
        #expect(Set(profile.disable) == ServiceCatalog.slimmable)
    }

    @Test("keep + disable always partition the slimmable catalog")
    func keepAndDisablePartitionCatalog() async throws {
        TestEnv.ready()
        let facts = try await AppInspector.inspect(TestEnv.fixture("Sample.app"))
        let (profile, _) = Profiler.derive(from: facts, keeping: ["com.apple.Maps.mapspushd", "not.a.catalog.label"])
        let kept = Set(profile.keep.keys)
        #expect(kept.isDisjoint(with: profile.disable))
        #expect(kept.union(profile.disable) == ServiceCatalog.slimmable)
        #expect(profile.keep["not.a.catalog.label"] == nil, "labels outside the catalog are not reported as kept")
        #expect(profile.disable == profile.disable.sorted())
    }

    @Test("--keep keeps a catalog service, with the reason")
    func explicitKeep() {
        TestEnv.ready()
        let profile = Profiler.full(keeping: ["com.apple.healthd"])
        #expect(profile.keep["com.apple.healthd"] == ["kept with --keep"])
        #expect(!profile.disable.contains("com.apple.healthd"))
    }

    @Test("Entitlements embedded in a simulator binary's __TEXT,__entitlements are read")
    func entitlementsFromBinary() async throws {
        TestEnv.ready()
        let dir = TestEnv.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("Plain.app")
        try FileManager.default.copyItem(at: TestEnv.fixture("Plain.app"), to: app)
        let entitlements = dir.appendingPathComponent("ent.plist")
        let plist: [String: Any] = ["aps-environment": "development", "com.apple.developer.healthkit": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: entitlements)
        let source = dir.appendingPathComponent("main.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        // The same section Xcode writes for simulator builds.
        try await Shell.xcrun("clang", "-o", app.appendingPathComponent("Plain").path, source.path,
                              "-Wl,-sectcreate,__TEXT,__entitlements,\(entitlements.path)")

        let facts = try await AppInspector.inspect(app)
        #expect(facts.entitlements.isSuperset(of: ["aps-environment", "com.apple.developer.healthkit"]))
        let (profile, _) = Profiler.derive(from: facts)
        #expect(profile.keep["com.apple.apsd"]?.contains { $0.contains("entitlement aps-environment") } == true)
        #expect(profile.keep["com.apple.healthd"] != nil)
    }

    @Test("otool -L output yields system frameworks only")
    func parseFrameworks() throws {
        let text = try String(contentsOf: TestEnv.fixture("otool-L.txt"), encoding: .utf8)
        #expect(AppInspector.parseFrameworks(text) == ["Foundation", "StoreKit", "PhotosUI"])
    }

    @Test("strict ignores linked frameworks, keeps declared capabilities")
    func strictIgnoresFrameworks() {
        TestEnv.ready()
        let facts = AppFacts(appPath: "/tmp/Lib.app", bundleIdentifier: "dev.fastios.lib",
                             infoPlistKeys: ["NSContactsUsageDescription"], backgroundModes: [],
                             entitlements: [], frameworks: ["StoreKit", "Photos"], extensionPoints: [])
        let loose = Profiler.derive(from: facts).profile
        let strict = Profiler.derive(from: facts, strict: true).profile
        #expect(loose.keep["com.apple.storekitd"] != nil)
        #expect(loose.keep["com.apple.assetsd"] != nil)
        #expect(strict.keep["com.apple.storekitd"] == nil)
        #expect(strict.keep["com.apple.assetsd"] == nil)
        #expect(strict.keep["com.apple.contactsd"] != nil)
        #expect(strict.name == "strict: Lib.app")
    }

    @Test("Services heal learned for an app are kept in its next profile")
    func learnedServicesAreKept() throws {
        TestEnv.ready()
        let bundleID = "dev.fastios.learned.\(UUID().uuidString)"
        try HealStore.learn(LearnedService(label: "com.apple.healthd", machService: "com.apple.healthd.server",
                                           evidence: "line", learnedAt: Date(), udid: "X"), bundleID: bundleID)
        defer { try? HealStore.forget(bundleID: bundleID) }
        let facts = AppFacts(appPath: "/tmp/L.app", bundleIdentifier: bundleID, infoPlistKeys: [],
                             backgroundModes: [], entitlements: [], frameworks: [], extensionPoints: [])
        let profile = Profiler.derive(from: facts, strict: true).profile
        #expect(profile.keep["com.apple.healthd"]?.first?.contains("learned by heal") == true)
        try HealStore.forget(bundleID: bundleID)
        #expect(Profiler.derive(from: facts).profile.keep["com.apple.healthd"] == nil)
    }

    @Test("Every label a capability rule keeps is in the catalog")
    func rulesNameRealLabels() {
        for rule in CapabilityMap.rules {
            for label in rule.keep {
                #expect(ServiceCatalog.slimmable.contains(label), "\(rule.trigger) keeps \(label), which is not slimmable")
            }
            #expect(!rule.reason.isEmpty)
        }
    }
}
