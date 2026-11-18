import Foundation
import Testing
@testable import FastIOSCore

@Suite("Heal: log line to launchd label, with cool-down and cap")
struct HealTests {
    static let map = ServiceMap(labelForMach: [
        "com.apple.photos.service": "com.apple.assetsd",
        "com.apple.assetsd": "com.apple.assetsd",
        "com.apple.contactsd": "com.apple.contactsd",
        "com.apple.healthd.server": "com.apple.healthd",
    ], plistForLabel: [:])

    static func lines() throws -> [String] {
        try String(contentsOf: TestEnv.fixture("heal-log.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    static func failure(_ service: String) -> Healer.Failure {
        Healer.Failure(process: "Probe", machService: service, line: "line")
    }

    @Test("Each known failure line yields its Mach service, only from watched processes")
    func parseLines() throws {
        let lines = try Self.lines()
        #expect(Healer.failure(in: lines[0], processes: ["Probe"])?.machService == "com.apple.photos.service")
        #expect(Healer.failure(in: lines[1], processes: ["Probe"])?.machService == "com.apple.contactsd")
        #expect(Healer.failure(in: lines[2], processes: ["Probe"]) == nil, "SpringBoard is not watched")
        #expect(Healer.failure(in: lines[2], processes: ["SpringBoard"])?.machService == "com.apple.apsd")
        #expect(Healer.failure(in: lines[3], processes: ["Probe"]) == nil, "no failure in this line")
        #expect(Healer.failure(in: "garbage", processes: ["Probe"]) == nil)
    }

    @Test("A failure on a disabled service maps to its label and is repaired")
    func repairsDisabledService() throws {
        var d = HealDecider(cooldown: 30, maxRepairs: 10)
        let f = try #require(Healer.failure(in: try Self.lines()[0], processes: ["Probe"]))
        #expect(d.decide(f, map: Self.map, disabled: { ["com.apple.assetsd"] }, now: Date()) == .repair(label: "com.apple.assetsd"))
        #expect(d.repairs == 1)
    }

    @Test("A short service name resolves through the com.apple. prefix")
    func shortName() {
        var d = HealDecider(cooldown: 30, maxRepairs: 10)
        #expect(d.decide(Self.failure("assetsd"), map: Self.map, disabled: { ["com.apple.assetsd"] }, now: Date())
                == .repair(label: "com.apple.assetsd"))
    }

    @Test("The same service is not retried within the cool-down, and is after it")
    func coolDown() {
        var d = HealDecider(cooldown: 30, maxRepairs: 10)
        let t0 = Date()
        let f = Self.failure("com.apple.photos.service")
        #expect(d.decide(f, map: Self.map, disabled: { ["com.apple.assetsd"] }, now: t0) == .repair(label: "com.apple.assetsd"))
        var read = false
        #expect(d.decide(f, map: Self.map, disabled: { read = true; return ["com.apple.assetsd"] }, now: t0 + 29) == .silent)
        #expect(!read, "a cooling-down label does not read the store")
        #expect(d.decide(f, map: Self.map, disabled: { ["com.apple.assetsd"] }, now: t0 + 31) == .repair(label: "com.apple.assetsd"))
        #expect(d.repairs == 2)
    }

    @Test("After the cap, further services are reported once and not repaired")
    func cap() {
        var d = HealDecider(cooldown: 30, maxRepairs: 1)
        let all: Set<String> = ["com.apple.assetsd", "com.apple.contactsd", "com.apple.healthd"]
        let now = Date()
        #expect(d.decide(Self.failure("com.apple.photos.service"), map: Self.map, disabled: { all }, now: now)
                == .repair(label: "com.apple.assetsd"))
        guard case .capReached(let label, let why) = d.decide(Self.failure("com.apple.contactsd"), map: Self.map,
                                                               disabled: { all }, now: now) else {
            Issue.record("expected capReached"); return
        }
        #expect(label == "com.apple.contactsd")
        #expect(why.contains("--max-repairs"))
        #expect(d.decide(Self.failure("com.apple.contactsd"), map: Self.map, disabled: { all }, now: now + 60) == .silent)
        guard case .capReached = d.decide(Self.failure("com.apple.healthd.server"), map: Self.map, disabled: { all }, now: now) else {
            Issue.record("each label is reported once"); return
        }
        #expect(d.repairs == 1)
    }

    @Test("A service that is not disabled is ignored, reported once")
    func notDisabled() {
        var d = HealDecider(cooldown: 30, maxRepairs: 10)
        let f = Self.failure("com.apple.contactsd")
        guard case .ignore(let label, let why) = d.decide(f, map: Self.map, disabled: { [] }, now: Date()) else {
            Issue.record("expected ignore"); return
        }
        #expect(label == "com.apple.contactsd")
        #expect(why.contains("not disabled"))
        #expect(d.decide(f, map: Self.map, disabled: { [] }, now: Date()) == .silent)
        #expect(d.repairs == 0)
    }

    @Test("A service fast-ios does not manage is ignored without a label")
    func unknownService() {
        var d = HealDecider(cooldown: 30, maxRepairs: 10)
        let f = Self.failure("com.example.vendor.daemon")
        guard case .ignore(nil, let why) = d.decide(f, map: Self.map, disabled: { [] }, now: Date()) else {
            Issue.record("expected ignore with no label"); return
        }
        #expect(why.contains("not a service fast-ios turns off"))
        #expect(d.decide(f, map: Self.map, disabled: { [] }, now: Date()) == .silent)
    }

    @Test("Heal events encode with a stable shape and are read back from repairs.jsonl")
    func repairsLog() throws {
        TestEnv.ready()
        let udid = "HEAL-\(UUID().uuidString)"
        var e = HealEvent(event: "repaired", udid: udid, bundleIdentifier: "dev.fastios.heal")
        e.label = "com.apple.assetsd"; e.repairMs = 120; e.savedToProfile = true
        HealStore.record(e)
        HealStore.record(HealEvent(event: "ignored", udid: udid, bundleIdentifier: "dev.fastios.heal"))
        let back = HealStore.repairs(udid: udid)
        #expect(back.count == 1, "only repaired and repair-failed events are listed")
        #expect(back.first?.label == "com.apple.assetsd")
        #expect(back.first?.repairMs == 120)
    }
}
