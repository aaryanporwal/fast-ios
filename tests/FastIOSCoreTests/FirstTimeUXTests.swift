import Foundation
import Testing
@testable import FastIOSCore

/// The fixes from docs/ux/first-time-notes.md (17 Nov 2026), one test each.
@Suite("First-time customer fixes", .serialized)
struct FirstTimeUXTests {
    static let warning = MemoryStatus(availableMB: 4700, totalMB: 24576, pressure: "warning")
    static let normal = MemoryStatus(availableMB: 9000, totalMB: 24576, pressure: "normal")
    static let mb: Int64 = 1_048_576

    // MARK: 1. run and lease under memory pressure (5.3, 5.4)

    @Test("doctor, lease and run judge memory with one rule, and a refusal names the next step")
    func memoryRuleAndAdvice() {
        let policy = AdmissionPolicy(needMB: 1500, reserveMB: 2048, maxPressure: "normal")
        #expect(MemoryAdvice.judge(Self.warning, policy: policy).canStart == policy.admits(Self.warning, pendingBoots: 0))
        #expect(MemoryAdvice.judge(Self.normal, policy: policy).canStart == policy.admits(Self.normal, pendingBoots: 0))
        #expect(!MemoryAdvice.judge(Self.warning, policy: policy).canStart)

        let running = TestEnv.device("AAAAAAAA-0000-0000-0000-000000000001")
        let leased = TestEnv.device("AAAAAAAA-0000-0000-0000-000000000003")
        let advice = MemoryAdvice.build(memory: Self.warning, policy: policy, devices: [running, leased],
                                        measured: [running.udid: SimMeasurement(processes: 90, bytes: 800 * Self.mb),
                                                   leased.udid: SimMeasurement(processes: 95, bytes: 2100 * Self.mb)],
                                        leasedBy: [leased.udid: "claude[42]"], pool: [leased.udid],
                                        apps: [running.udid: ["com.example.myapp"]],
                                        otherSimulators: (2, 1900), largestApps: [("Xcode", 3100)])
        #expect(!advice.canStartNew)
        #expect(advice.why.contains("memory pressure as warning"))
        // Each running simulator: name, UDID, memory, who holds it, apps; largest first.
        #expect(advice.simulators.map(\.udid) == [leased.udid, running.udid])
        #expect(advice.usage.contains("- Test iPhone (\(leased.udid)): 2100 MB, leased by claude[42]."))
        #expect(advice.usage.contains("- Test iPhone (\(running.udid)): 800 MB, not from the fast-ios pool, apps running: com.example.myapp."))
        #expect(advice.usage.contains { $0.contains("not which one is in front") })
        #expect(advice.usage.contains { $0.contains("2 more simulators") && $0.contains("1.9 GB") })
        #expect(advice.usage.contains { $0.contains("Xcode 3.0 GB") })
        #expect(advice.largestApps == [AppMemory(name: "Xcode", memoryMB: 3100)])
        // The choices, in order: reuse one nobody leases, start anyway, shut one down.
        let reuse = advice.nextStep.range(of: "fast-ios run --simulator \(running.udid)")
        let anyway = advice.nextStep.range(of: "--max-pressure warning")
        let stop = advice.nextStep.range(of: "shutdown \(running.udid)")
        #expect(reuse != nil && anyway != nil && stop != nil)
        if let reuse, let anyway, let stop { #expect(reuse.lowerBound < anyway.lowerBound && anyway.lowerBound < stop.lowerBound) }
        #expect(!advice.nextStep.contains(leased.udid), "never suggests a simulator another agent holds")
    }

    @Test("Only non-Apple apps are listed from a simulator's launchd jobs")
    func appsFromLaunchctl() {
        let text = """
        PID\tStatus\tLabel
        4079\t0\tUIKitApplication:com.apple.mobilecal[0cb4][rb-legacy]
        3197\t0\tUIKitApplication:com.example.myapp[9074][rb-legacy]
        3198\t0\tUIKitApplication:com.example.myapp[9075][rb-legacy]
        -\t0\tcom.apple.backboardd
        """
        #expect(MemoryAdvice.appIDs(fromLaunchctlList: text) == ["com.example.myapp"])
    }

    @Test("A Mac short of memory refuses at once; a wait for other agents' starts goes on")
    func admissionFailsFast() {
        let policy = AdmissionPolicy(needMB: 1500, reserveMB: 2048, maxPressure: "normal")
        // Warning pressure: refused for memory, first in line or not.
        guard case .wait(let reason, _) = LeaseManager.admission(position: 0, pending: 0, memory: Self.warning, policy: policy, idle: nil),
              case .wait(let behind, _) = LeaseManager.admission(position: 2, pending: 0, memory: Self.warning, policy: policy, idle: nil) else {
            Issue.record("expected a wait"); return
        }
        #expect(reason == "memory" && behind == "memory")
        // An idle pool simulator is shut down first, and the head of the queue does it.
        #expect(LeaseManager.admission(position: 0, pending: 0, memory: Self.warning, policy: policy, idle: "IDLE") == .reclaim("IDLE"))
        guard case .wait("queue", _) = LeaseManager.admission(position: 1, pending: 0, memory: Self.warning, policy: policy, idle: "IDLE") else {
            Issue.record("behind the head, an idle simulator means wait in the queue"); return
        }
        // Enough memory for one, but another is still starting: wait in the queue.
        let one = MemoryStatus(availableMB: 4000, totalMB: 24576, pressure: "normal")
        guard case .wait("queue", let detail) = LeaseManager.admission(position: 0, pending: 1, memory: one, policy: policy, idle: nil) else {
            Issue.record("expected a queue wait"); return
        }
        #expect(detail.hasPrefix("1 other simulator was still starting"))
        #expect(LeaseManager.admission(position: 0, pending: 0, memory: Self.normal, policy: policy, idle: nil) == .go)
        #expect(LeaseManager.admission(position: 0, pending: 0, memory: Self.warning, policy: AdmissionPolicy(maxPressure: "warning"), idle: nil) == .go)

        // By default memory gets no wait; the queue gets 5 min; --wait-for-memory raises both.
        var req = LeaseRequest(profile: Profiler.full())
        #expect(LeaseManager.waitLimit(reason: "memory", req) == 0)
        #expect(LeaseManager.waitLimit(reason: "queue", req) == 300)
        req.memoryWait = 600
        #expect(LeaseManager.waitLimit(reason: "memory", req) == 600 && LeaseManager.waitLimit(reason: "queue", req) == 600)
    }

    @Test("The refusal reads as an outcome and a next step, and run --json says memory_pressure")
    func waitsAndRefusalText() {
        #expect(LeaseManager.duration(30) == "30 s" && LeaseManager.duration(300) == "5 min" && LeaseManager.duration(90) == "1 min 30 s")
        let now = LeaseRefusal(status: "refused", reason: "memory", detail: "memory pressure is warning", waitedSeconds: 0,
                               queuePosition: 0, memory: Self.warning, policy: AdmissionPolicy(maxPressure: "normal"))
        #expect(now.headline == "No simulator was started: macOS reports memory pressure as warning (4700 MB free), and fast-ios starts a new simulator only at normal pressure.")
        var r = LeaseRefusal(status: "refused", reason: "memory", detail: "memory pressure is warning", waitedSeconds: 30,
                             queuePosition: 0, memory: Self.warning, policy: AdmissionPolicy(maxPressure: "normal"))
        r.nextStep = "Shut down a simulator."
        let text = r.localizedDescription
        #expect(text.hasPrefix("No simulator was started: after waiting 30 s, macOS reports memory pressure as warning"))
        #expect(text.contains("Next: Shut down a simulator."))
        #expect(!text.contains("lease refused"))
        // run --json keeps the old error shape and adds the next step.
        let json = JSONOutput.error(r)
        #expect(json["error"]?["nextStep"]?.string == "Shut down a simulator.")
        #expect(json["error"]?["code"]?.string == "memory_pressure")
        #expect(json["error"]?["reason"]?.string == "memory")
        #expect(json["error"]?["memory"]?["pressure"]?.string == "warning")
        #expect(json["error"]?["simulators"]?.array != nil && json["error"]?["largestApps"]?.array != nil)
        let queue = LeaseRefusal(status: "refused", reason: "queue", detail: "1 other simulator was still starting", waitedSeconds: 300,
                                 queuePosition: 0, memory: Self.normal, policy: AdmissionPolicy())
        #expect(JSONOutput.classify(queue).code == "queue_timeout")
        #expect(queue.headline == "No simulator was started: after waiting 300 s, 1 other simulator was still starting.")
    }

    // MARK: 2. run shows the app (5.5)

    @Test("A Simulator window opens only for the normal device set, and says why not otherwise")
    func simulatorWindowPlan() {
        let udid = "AAAAAAAA-0000-0000-0000-000000000002"
        #expect(SimulatorWindow.plan(udid: udid, name: "UX iPhone", deviceSet: nil, simulatorAppInstalled: true)
                == .opened("Opened the Simulator app on UX iPhone."))
        guard case .notPossible(let other) = SimulatorWindow.plan(udid: udid, name: "UX iPhone", deviceSet: "/tmp/sims", simulatorAppInstalled: true)
        else { Issue.record("a custom set cannot get a window"); return }
        #expect(other.contains("separate set of simulators") && other.contains("fast-ios shot --udid \(udid)"))
        guard case .notPossible(let missing) = SimulatorWindow.plan(udid: udid, name: "UX iPhone", deviceSet: nil, simulatorAppInstalled: false)
        else { Issue.record("no Simulator app, no window"); return }
        #expect(missing.contains("Simulator app was not found"))
    }

    // MARK: 3. saved after off then on (4.9)

    static func obs(_ udid: String, disk: Set<String> = [], live: Set<String>? = nil, bytes: Int64, age: TimeInterval,
                    madeFull: Date? = nil) -> Savings.Observation {
        Savings.Observation(udid: udid, runtime: "iOS-27-0", deviceType: "iPhone-18-Pro", isBooted: true,
                            diskDisabled: disk, liveDisabled: live,
                            measurement: SimMeasurement(processes: 90, bytes: bytes), bootAge: age,
                            fullAfterRestartSince: madeFull)
    }

    static let someLabel = ServiceCatalog.slimmable.sorted()[0]

    @Test("Off then on: a still-light simulator is never stored as the full size, and saved stays about 2 GB")
    func offThenOn() {
        let now = Date()
        // Started 10 min ago light; `off` 5 min ago enabled everything (files and launchd say full).
        let afterOff = Self.obs("U1", live: [], bytes: 792 * Self.mb, age: 600, madeFull: now.addingTimeInterval(-300))
        #expect(!Savings.isReallyFull(afterOff, now: now))
        #expect(afterOff.isRunningLight(now: now))
        var store = BaselineStore()
        let r1 = store.record([afterOff], now: now)
        #expect(!r1)
        #expect(store.entries.isEmpty)
        // After `on`, saved compares with the estimate, labelled so.
        let s = Savings.saving(for: afterOff, store: store)
        #expect(s?.baseline.source == .estimated && s?.baseline.label == "estimated")
        #expect((s?.saved ?? 0) == Savings.estimatedFullBytes - 792 * Self.mb)
        #expect((s?.saved ?? 0) > 2_000 * Self.mb)
    }

    @Test("On then off then a restart: the really full size is measured and then used, labelled measured")
    func onThenOff() {
        let now = Date()
        let madeFull = now.addingTimeInterval(-900)
        // Restarted 5 min ago, after `off`: really full.
        let full = Self.obs("U2", live: [], bytes: 2_900 * Self.mb, age: 300, madeFull: madeFull)
        #expect(Savings.isReallyFull(full, now: now))
        var store = BaselineStore()
        let r2 = store.record([full], now: now)
        #expect(r2)
        #expect(store.entries["U2"]?.bytes == 2_900 * Self.mb)
        // Light again later: saved is measured on this simulator.
        let light = Self.obs("U2", disk: [Self.someLabel], live: [Self.someLabel], bytes: 800 * Self.mb, age: 400)
        let s = Savings.saving(for: light, store: store)
        #expect(s?.baseline.source == .measured(now) && s?.baseline.isMeasured == true)
        #expect(s?.saved == 2_100 * Self.mb)
        // Another simulator of the same model borrows it, labelled as such.
        let peer = Self.obs("U3", disk: [Self.someLabel], bytes: 700 * Self.mb, age: 400)
        #expect(Savings.saving(for: peer, store: store)?.baseline.label == "measured on the same model")
    }

    @Test("A simulator that was already light, or has not settled, is never measured as full")
    func alreadyLightOrSettling() {
        let now = Date()
        var store = BaselineStore()
        let r3 = store.record([Self.obs("L1", disk: [Self.someLabel], bytes: 700 * Self.mb, age: 900)], now: now)
        #expect(!r3)
        let r4 = store.record([Self.obs("L2", live: [Self.someLabel], bytes: 700 * Self.mb, age: 900)], now: now)
        #expect(!r4)
        let early = Self.obs("L3", bytes: 1_500 * Self.mb, age: 60)
        let r5 = store.record([early], now: now)
        #expect(!r5)
        #expect(store.entries.isEmpty)
        // A light one that just started is "too early".
        let fresh = Self.obs("L4", disk: [Self.someLabel], bytes: 395 * Self.mb, age: 60)
        #expect(Savings.saving(for: fresh, store: store)?.settling == true)
        #expect(Savings.total([Savings.saving(for: fresh, store: store)!])?.settling == true)
    }

    @Test("A baselines file from the old rule (no version) is dropped, a current one is kept")
    func oldBaselinesDropped() throws {
        let dir = TestEnv.temp()
        let url = dir.appendingPathComponent("stock-baselines.json")
        let old = #"{"entries":{"U9":{"bytes":830597072,"processes":90,"runtime":"r","deviceType":"d","measuredAt":"2026-11-17T10:00:00Z"}}}"#
        try Data(old.utf8).write(to: url)
        #expect(BaselineStore.load(from: url).entries.isEmpty)
        var store = BaselineStore()
        store.record([Self.obs("U9", bytes: 2_800 * Self.mb, age: 600)])
        try store.save(to: url)
        #expect(BaselineStore.load(from: url).entries["U9"]?.bytes == 2_800 * Self.mb)
    }

    @Test("off records when a running simulator was made full, so it reads as light until its restart")
    func offRecordsStillLight() async throws {
        // In memory, not state.json: other suites share the test state folder.
        let udid = "AAAAAAAA-0000-0000-0000-0000000000F1"
        var state = FastIOSState()
        state.fullAfterRestart = [udid: Date().addingTimeInterval(-600)]
        let d = TestEnv.device(udid)
        let o = Savings.Observation(d, diskDisabled: [], bootAge: 3600, state: state)
        #expect(o.startedBeforeMadeFull())
        #expect(o.isRunningLight())
        let restarted = Savings.Observation(d, diskDisabled: [], bootAge: 60, state: state)
        #expect(!restarted.startedBeforeMadeFull())
        // The field round-trips, and an old state.json without it still loads.
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(FastIOSState.self, from: data).fullAfterRestart?[udid] != nil)
        #expect(try JSONDecoder().decode(FastIOSState.self, from: Data(#"{"devices":{}}"#.utf8)).fullAfterRestart == nil)
    }

    // MARK: 4. --keep (2.5, 5.9)

    @Test("--keep takes a category ID, a category name or a label, and refuses anything else with the list")
    func keepNames() throws {
        let widgets = try #require(ServiceCatalog.categories.first { $0.id == "widgets" })
        let expected = widgets.labels.filter { ServiceCatalog.slimmable.contains($0) }
        #expect(KeepNames.labels(for: "widgets") == expected)
        #expect(KeepNames.labels(for: "Widgets & Wallpaper") == expected)
        #expect(KeepNames.labels(for: "widgets and wallpaper") == expected)
        #expect(KeepNames.labels(for: "com.apple.chronod") == ["com.apple.chronod"])
        #expect(KeepNames.labels(for: "com.apple.SpringBoard") == [])  // never off anyway
        #expect(throws: UsageError.self) { try KeepNames.validate(["widgetz"]) }
        #expect(KeepNames.unknownMessage("widgetz").contains("widgets, siri"))

        let p = Profiler.full(keeping: ["widgets"])
        #expect(Set(p.keep.keys) == Set(expected))
        #expect(p.keep["com.apple.chronod"] == ["kept with --keep widgets"])
        #expect(Set(p.disable).isDisjoint(with: expected))
    }

    // MARK: 6.3 undo everything

    @Test("Leftovers lists fast-ios's own files, and removeFiles deletes them and nothing else")
    func leftovers() async throws {
        TestEnv.ready()
        let cache = TestEnv.temp("cache-\(UUID().uuidString)")
        setenv("FASTIOS_CACHE_DIR", cache.path, 1)
        setenv("FASTIOS_BIN_DIR", TestEnv.temp().path, 1)
        setenv("FASTIOS_APP_PATH", TestEnv.temp().appendingPathComponent("absent.app").path, 1)
        defer { unsetenv("FASTIOS_CACHE_DIR"); unsetenv("FASTIOS_BIN_DIR"); unsetenv("FASTIOS_APP_PATH") }
        let log = TestEnv.temp().appendingPathComponent("helper.log")
        try Data("x".utf8).write(to: log)
        let config = AutoModeConfig(executablePath: "/bin/true", label: "dev.fast-ios.leftovers-test",
                                    launchAgentsFolder: TestEnv.temp(), logFile: log)
        let found = await Leftovers.find(config)
        #expect(Set(found.map(\.kind)).isSuperset(of: [.state, .cache, .log]))
        #expect(!found.contains { $0.kind == .helper })
        let keep = TestEnv.temp().appendingPathComponent("unrelated")
        try Data().write(to: keep)
        let (removed, failed) = Leftovers.removeFiles(found.filter { $0.kind != .state })
        #expect(failed.isEmpty && removed.count == 2)
        #expect(!FileManager.default.fileExists(atPath: cache.path) && !FileManager.default.fileExists(atPath: log.path))
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }
}

/// The same fixes, through the built program.
@Suite("First-time customer fixes in the fast-ios program", .serialized)
struct FirstTimeUXCLITests {
    func run(_ args: [String]) throws -> CLIBinaryTests.Run {
        try CLIBinaryTests.run(args, stateDir: TestEnv.temp().appendingPathComponent("state"))
    }

    @Test("Help and errors say light and full, never slim or stock (the slim command keeps its name)")
    func twoWords() throws {
        guard CLIBinaryTests.binary != nil else { Issue.record("fast-ios was not built next to the tests"); return }
        var texts = [try run(["help"]).out, try run(["help", "--json"]).out]
        for c in try CLIBinaryTests.commands() where c != "version" { texts.append(try run([c, "--help"]).out) }
        for t in texts {
            // Allowed: the command's own name (in `fast-ios slim`, the help list
            // and the MCP tool list) and the other tool's name, simslim.
            let words = t.split(separator: "\n").filter { !$0.hasPrefix("  slim ") }.joined(separator: "\n")
                .replacingOccurrences(of: "fast-ios slim", with: "").replacingOccurrences(of: "simslim", with: "")
                .replacingOccurrences(of: "\"slim\"", with: "").replacingOccurrences(of: ", slim,", with: "")
            for bad in [" slim", "Slim", "slimm", "stock", "Stock"] {
                #expect(!words.contains(bad), "help text says \"\(bad)\": \(t.prefix(300))")
            }
        }
    }

    @Test("status --help lists --verbose; release without a UDID and an unknown --keep say what to do")
    func smallErrors() throws {
        guard CLIBinaryTests.binary != nil else { Issue.record("fast-ios was not built next to the tests"); return }
        #expect(try run(["status", "--help"]).out.contains("--verbose"))
        let release = try run(["release"])
        #expect(release.status == 64 && release.err.contains("release needs the UDID") && !release.err.contains("arguments."))
        let notLeased = try run(["release", "ABC"])
        #expect(notLeased.status == 1 && notLeased.err.contains("ABC is not leased"))
        let keep = try run(["profile", "/nonexistent.app", "--keep", "widgetz"])
        #expect(keep.status == 64 && keep.err.contains("--keep does not know \"widgetz\"") && keep.err.contains("widgets"))
        let shot = try run(["shot", "--json"])
        #expect(shot.out.contains("needs --app") && !shot.out.contains("arguments.app"))
        let heal = try run(["heal", "booted", "--app"])
        #expect(heal.status == 64 && heal.err.contains("bundle id"))
    }

    @Test("uninstall --dry-run lists what it would remove and changes nothing")
    func uninstallDryRun() throws {
        guard CLIBinaryTests.binary != nil else { Issue.record("fast-ios was not built next to the tests"); return }
        let state = TestEnv.temp().appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let r = try CLIBinaryTests.run(["uninstall", "--dry-run", "--set", TestEnv.temp().path], stateDir: state)
        #expect(r.status == 0, "\(r.out)\(r.err)")
        #expect(r.out.contains("Dry run: nothing was changed") && r.out.contains(state.path))
        #expect(FileManager.default.fileExists(atPath: state.path))
    }
}
