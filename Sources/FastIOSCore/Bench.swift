import Foundation

/// `fast-ios bench`: stock vs fast-ios vs simslim on throwaway simulators in a
/// private device set, one simulator at a time. The source of every number
/// fast-ios publishes.
///
/// Per variant, on a newly created (never booted) simulator:
/// - slimSeconds: the slim command on the shut-down simulator. fast-ios:
///   `fast-ios slim <udid> --full` (or `--app`). simslim: `simslim on <udid>`,
///   which boots stock, disables, and reboots slim, so it ends booted.
/// - firstReadySeconds: from the fresh shut-down simulator to slim, booted and
///   ready (`simctl bootstatus -b` returned). stock: the first boot.
/// - coldBootSeconds: shut down, then boot to ready again (second boot).
/// - processes / memoryBytes: `settleSeconds` after that cold boot, every
///   process under the simulator's launchd_sim, summed `footprint`.
/// CLI start-up: median wall time of `help` and of the list command.
public struct BenchOptions: Sendable {
    public var variants: [String] = ["stock", "fast-ios", "simslim"]
    public var settleSeconds: Int = 180
    public var runtime: String?
    public var deviceType: String?
    /// The fast-ios binary to measure (normally this one).
    public var fastIOSPath: String
    public var simslimPath: String?
    /// Derive fast-ios's profile from this app instead of `--full`.
    public var app: String?
    public var startupRuns: Int = 10
    /// Fresh simulators per variant. Rounds interleave the variants
    /// (stock, fast-ios, simslim, stock, …) so load drift hits each alike.
    public var repeats: Int = 1
    /// "boot" (the variants above), "app" (time to the app running), "all",
    /// or "shot" (shot timings, in the default device set). "app" and "shot" need `app`.
    public var scenario: String = "boot"
    /// Scenario "parallel": concurrent `fast-ios run` calls per round.
    public var agents: Int = 3
    /// Scenario "parallel": the first agent's first boot hangs past a 1 s
    /// deadline (FASTIOS_INJECT_BOOT_TIMEOUT), to exercise replacement.
    public var injectFault = false
    public init(fastIOSPath: String) { self.fastIOSPath = fastIOSPath }
}

public struct BenchHost: Encodable, Sendable {
    public let model: String
    public let cpu: String
    public let memoryGB: Int
    public let macOS: String
    public let xcode: String
}

public struct BenchVariant: Encodable, Sendable {
    /// "stock", "fast-ios" or "simslim".
    public let variant: String
    /// The command that slimmed the simulator, or null for stock.
    @EncodeNull public var slimCommand: String?
    /// Medians over `runs` fresh simulators.
    @EncodeNull public var slimSeconds: Double?
    public let firstReadySeconds: Double
    public let coldBootSeconds: Double
    /// Every run's value, in run order.
    public let slimSamples: [Double]
    public let firstReadySamples: [Double]
    public let coldBootSamples: [Double]
    public let runs: Int
    /// Measured once, after the first run's cold boot and the settle time.
    public let processes: Int
    public let memoryBytes: Int64
    /// Labels launchd reports as disabled after the cold boot.
    public let servicesDisabled: Int
    /// Memory pressure when the variant started and when it was measured.
    public let pressureBefore: String
    public let pressureAfter: String
    /// True when pressure was not "normal": timings are not comparable.
    public let noisy: Bool
}

public struct BenchStartup: Encodable, Sendable {
    public let tool: String
    public let command: String
    public let runs: Int
    public let medianMs: Double
    public let minMs: Double
}

/// One way to get from nothing to the app running on a slim simulator.
public struct BenchAppMethod: Encodable, Sendable {
    /// "stock + simctl", "simslim + simctl", "fast-ios run (cold)",
    /// "fast-ios run (warm, same build)", "fast-ios run (warm, changed build)".
    public let method: String
    /// The steps timed, as commands.
    public let steps: String
    /// Median seconds from the first step until `simctl launch` returned.
    public let seconds: Double
    public let samples: [Double]
}

/// Something fast-ios does that simslim has no command for, stated as a
/// fact with what was measured, not as a speed claim.
public struct BenchCapability: Encodable, Sendable {
    public let name: String
    public let fastIOS: String
    public let simslim: String
    /// True when `fastIOS` holds a number this bench run measured.
    public let measured: Bool
}

/// One round of N agents calling `fast-ios run` at the same moment.
public struct BenchParallelRound: Encodable, Sendable {
    public let agents: Int
    public let succeeded: Int
    /// Simulators retired and replaced across all agents.
    public let retries: Int
    /// From the first call until the last one returned.
    public let wallSeconds: Double
    public let agentSeconds: [Double]
    public let replaced: [Replacement]
    public let errors: [String]
    /// Lowest available memory and worst pressure seen during the round.
    public let minAvailableMB: Int
    public let worstPressure: String
}

public struct BenchOutput: Encodable, Sendable {
    public var schemaVersion = JSONOutput.schemaVersion
    public let date: String
    public let host: BenchHost
    public let runtime: String
    public let deviceType: String
    /// "full" or the app fast-ios derived its profile from.
    public let fastIOSProfile: String
    @EncodeNull public var simslimVersion: String?
    public let settleSeconds: Int
    public let variants: [BenchVariant]
    /// Time to the app running, per method (scenario "app"). Empty otherwise.
    public let app: [BenchAppMethod]
    /// Shot timings and sizes (scenario "shot"). Empty otherwise.
    public var shot: [BenchShotRow] = []
    /// Scenario "parallel": one entry per round. Empty otherwise.
    public let parallel: [BenchParallelRound]
    public let capabilities: [BenchCapability]
    public let startup: [BenchStartup]
    /// True when any variant ran under memory pressure.
    public let noisy: Bool
    public let notes: [String]
}

public enum Bench {
    public static func run(_ o: BenchOptions, log: Log) async throws -> BenchOutput {
        if o.scenario == "shot" { return try await shotScenario(o, log: log) }
        let setPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("fast-ios-bench-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: setPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: setPath) }
        let previousSet = ProcessInfo.processInfo.environment["FASTIOS_DEVICE_SET"]
        setenv("FASTIOS_DEVICE_SET", setPath, 1)
        defer { if let previousSet { setenv("FASTIOS_DEVICE_SET", previousSet, 1) } else { unsetenv("FASTIOS_DEVICE_SET") } }

        let (runtime, deviceType) = try await LeaseManager.resolveTarget(runtime: o.runtime, deviceType: o.deviceType)
        log("Device set \(setPath); \(deviceType) on \(runtime); \(o.settleSeconds) s settle")
        var notes: [String] = []
        var simslimVersion: String?
        if let s = o.simslimPath {
            simslimVersion = (try? await Shell.run(s, ["--version"], check: false))?.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var variants = o.variants
        if variants.contains("simslim") && o.simslimPath == nil {
            notes.append("simslim is not installed: its variant was skipped.")
            variants.removeAll { $0 == "simslim" }
        }
        var samples: [String: [Sample]] = [:]
        if o.scenario == "app" || o.scenario == "parallel" { variants = [] }
        if o.scenario != "boot" && o.app == nil {
            throw UsageError("The \(o.scenario) scenario needs --app <built .app or folder>.")
        }
        for round in 1...max(1, o.repeats) where !variants.isEmpty {
            for variant in variants {
                log("[\(variant)] run \(round) of \(max(1, o.repeats)): creating a simulator")
                let udid = try await Simctl.simctl("create", "fast-ios-bench-\(variant)", deviceType, runtime).text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                do {
                    samples[variant, default: []].append(
                        try await measureVariant(variant, udid: udid, setPath: setPath, o: o, measureMemory: round == 1, log: log))
                } catch {
                    await discard(udid)
                    throw error
                }
                await discard(udid)
            }
        }
        let results = variants.compactMap { v in samples[v].map { aggregate(v, $0) } }
        var appMethods: [BenchAppMethod] = []
        var appNoisy = false
        if o.scenario == "app" || o.scenario == "all", let app = o.app {
            (appMethods, appNoisy) = try await appScenario(app: app, o: o, setPath: setPath, runtime: runtime,
                                                           deviceType: deviceType, log: log)
        }
        var parallel: [BenchParallelRound] = []
        if o.scenario == "parallel", let app = o.app {
            parallel = try await parallelScenario(app: app, o: o, setPath: setPath, log: log)
            if parallel.contains(where: { $0.worstPressure != "normal" }) {
                appNoisy = true
                notes.append("The parallel rounds ran under memory pressure (a loaded Mac): wall times are not comparable to a quiet Mac.")
            }
            notes.append("Parallel agents run with FASTIOS_TEMPLATE=off, so every agent creates its simulator; lease admission queues boots while memory is short.")
        }
        let capabilities = await capabilityRows(o)

        log("CLI start-up: \(o.startupRuns) runs each")
        var startup: [BenchStartup] = []
        startup.append(try await timeCommand("fast-ios", o.fastIOSPath, ["help"], runs: o.startupRuns))
        startup.append(try await timeCommand("fast-ios", o.fastIOSPath, ["status", "--json"], runs: o.startupRuns, unsetSet: true))
        if let s = o.simslimPath {
            startup.append(try await timeCommand("simslim", s, ["--help"], runs: o.startupRuns))
            startup.append(try await timeCommand("simslim", s, ["list"], runs: o.startupRuns, unsetSet: true))
            notes.append("List commands run on the default device set: `fast-ios status --json` and `simslim list` (simslim also scans Xcode's testing set).")
        }
        if o.variants.contains("simslim") {
            notes.append("simslim's time is `simslim on`, its one-shot command; `simslim watch` can also slim before the first boot and is not measured here.")
        }
        let noisy = results.contains(where: \.noisy) || appNoisy
        if noisy { notes.append("Memory pressure was not normal during at least one variant: timings are noisy. Rerun on a quiet Mac.") }

        return BenchOutput(
            date: ISO8601DateFormatter().string(from: Date()), host: await host(), runtime: runtime, deviceType: deviceType,
            fastIOSProfile: o.app ?? "full", simslimVersion: simslimVersion, settleSeconds: o.settleSeconds,
            variants: results, app: appMethods, parallel: parallel, capabilities: capabilities, startup: startup,
            noisy: noisy, notes: notes)
    }

    // MARK: - N agents at once

    /// Per round: `agents` concurrent `fast-ios run` calls into an empty pool,
    /// then every simulator they got is released and deleted (all were
    /// created by fast-ios in the private set).
    static func parallelScenario(app: String, o: BenchOptions, setPath: String, log: Log) async throws -> [BenchParallelRound] {
        let appURL = try AppInspector.locateApp(app)
        let args = ["run", "--app", appURL.path, "--set", setPath, "--max-pressure", "warning",
                    "--timeout", "10m", "--ttl", "15m", "--json"]
        var rounds: [BenchParallelRound] = []
        for round in 1...max(1, o.repeats) {
            log("[parallel] round \(round) of \(max(1, o.repeats)): \(o.agents) agents at once\(o.injectFault ? ", fault injected into agent 1" : "")")
            let sampler = MemorySampler()
            let sampling = Task { await sampler.run() }
            let start = ContinuousClock.now
            let results: [(Int, Double, ShellResult?)] = await withTaskGroup(of: (Int, Double, ShellResult?).self) { group in
                for i in 0..<max(1, o.agents) {
                    var env = ["FASTIOS_MAX_IDLE": "\(o.agents)", "FASTIOS_TEMPLATE": "off"]
                    if o.injectFault && i == 0 { env["FASTIOS_INJECT_BOOT_TIMEOUT"] = "1" }
                    let fastIOS = o.fastIOSPath
                    group.addTask {
                        var out: ShellResult?
                        let t = (try? await timed { out = try await Shell.run(fastIOS, args, check: false, environment: env) }) ?? 0
                        return (i, t, out)
                    }
                }
                var all: [(Int, Double, ShellResult?)] = []
                for await r in group { all.append(r) }
                return all.sorted { $0.0 < $1.0 }
            }
            let wall = ContinuousClock.now - start
            sampling.cancel()
            let (minMB, worst) = await sampler.result()

            var succeeded = 0
            var replaced: [Replacement] = []
            var errors: [String] = []
            var udids: [String] = []
            for (i, _, out) in results {
                guard let out, let v = try? JSONDecoder().decode(JSONValue.self, from: out.stdout) else {
                    errors.append("agent \(i + 1): no JSON output"); continue
                }
                if let u = v["udid"]?.string { udids.append(u) }
                if v["launched"]?.bool == true { succeeded += 1 } else {
                    errors.append("agent \(i + 1): \(v["error"]?["message"]?.string ?? "did not launch")")
                }
                for r in v["replaced"]?.array ?? [] {
                    if let data = try? JSONEncoder().encode(r), let rep = try? JSONDecoder().decode(Replacement.self, from: data) {
                        replaced.append(rep)
                    }
                }
            }
            // Clean up: every simulator in the private set was made by fast-ios.
            for u in udids { _ = try? await LeaseManager.release(u, shutdown: true) }
            for d in (try? await Simctl.listDevices()) ?? [] { await discard(d.udid) }
            _ = try? await LeaseManager.list()

            let seconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
            let round = BenchParallelRound(
                agents: o.agents, succeeded: succeeded, retries: replaced.count, wallSeconds: round2(seconds),
                agentSeconds: results.map { round2($0.1) }, replaced: replaced, errors: errors,
                minAvailableMB: minMB, worstPressure: worst)
            log("[parallel] \(succeeded)/\(o.agents) launched, \(replaced.count) replaced, wall \(fmt(seconds)) s, worst pressure \(worst)")
            rounds.append(round)
        }
        return rounds
    }

    // MARK: - Time to the app running

    /// Per round: stock + simctl, simslim + simctl, `fast-ios run` on an empty
    /// pool (cold), then `fast-ios run` again after release (warm). Each method
    /// starts from nothing (create included) and ends when `simctl launch`
    /// returns, which is when the app process exists, not when its first
    /// frame is drawn. One simulator runs at a time.
    static func appScenario(app: String, o: BenchOptions, setPath: String, runtime: String, deviceType: String,
                            log: Log) async throws -> ([BenchAppMethod], Bool) {
        let appURL = try AppInspector.locateApp(app)
        guard let bundle = try await AppInspector.inspect(appURL).bundleIdentifier else {
            throw InspectError(message: "\(appURL.path) has no CFBundleIdentifier, so it cannot be launched.")
        }
        var times: [String: [Double]] = [:]
        var noisy = false
        // Keep one released simulator warm whatever `fast-ios pool --size` says.
        let previousIdle = ProcessInfo.processInfo.environment["FASTIOS_MAX_IDLE"]
        setenv("FASTIOS_MAX_IDLE", "1", 1)
        defer { if let previousIdle { setenv("FASTIOS_MAX_IDLE", previousIdle, 1) } else { unsetenv("FASTIOS_MAX_IDLE") } }
        func note() { if MemoryStatus.read().pressure != "normal" { noisy = true } }
        // Today's cold path: no template.
        let runEnv = ["FASTIOS_MAX_IDLE": "1", "FASTIOS_TEMPLATE": "off"]
        let templateEnv = ["FASTIOS_MAX_IDLE": "1"]
        let runArgs = ["run", "--app", appURL.path, "--set", setPath, "--max-pressure", "warning", "--ttl", "10m", "--json"]

        // The slim template, built once; its cost is reported as its own row.
        log("[app] building the slim template (once)")
        note()
        let templateBuild = try await timed { try await Templates.build(runtime: runtime, deviceType: deviceType, log: log) }
        times["fast-ios template build (once per runtime and device type)", default: []].append(templateBuild)
        func appRounds() async throws {
        for round in 1...max(1, o.repeats) {
            log("[app] run \(round) of \(max(1, o.repeats)): stock + simctl")
            note()
            var udid = ""
            let stock = try await timed {
                udid = try await Simctl.simctl("create", "fast-ios-bench-app-stock", deviceType, runtime).text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try await Simctl.bootAndWait(udid)
                try await Simctl.simctl("install", udid, appURL.path)
                try await Simctl.simctl("launch", udid, bundle)
            }
            await discard(udid)
            times["stock + simctl", default: []].append(stock)
            log("[app] stock + simctl \(fmt(stock)) s")

            if let simslim = o.simslimPath {
                log("[app] simslim + simctl")
                note()
                let t = try await timed {
                    udid = try await Simctl.simctl("create", "fast-ios-bench-app-simslim", deviceType, runtime).text
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    try await Shell.run(simslim, ["--set", setPath, "on", udid])
                    if try await Simctl.device(udid).isBooted == false { try await Simctl.bootAndWait(udid) }
                    try await Simctl.simctl("install", udid, appURL.path)
                    try await Simctl.simctl("launch", udid, bundle)
                }
                await discard(udid)
                times["simslim + simctl", default: []].append(t)
                log("[app] simslim + simctl \(fmt(t)) s")
            }

            log("[app] fast-ios run (cold)")
            note()
            var out = ShellResult(status: 0, stdout: Data(), stderr: "")
            let cold = try await timed { out = try await Shell.run(o.fastIOSPath, runArgs, environment: runEnv) }
            let first = try JSONDecoder().decode(JSONValue.self, from: out.stdout)
            guard let leased = first["udid"]?.string, first["launched"]?.bool == true else {
                throw ShellError(command: "fast-ios run", status: out.status, stderr: "did not launch: \(out.text)")
            }
            times["fast-ios run (cold)", default: []].append(cold)
            log("[app] fast-ios run (cold) \(fmt(cold)) s")
            _ = try await LeaseManager.release(leased)  // stays booted: the warm pool

            log("[app] fast-ios run (warm)")
            note()
            let warm = try await timed { out = try await Shell.run(o.fastIOSPath, runArgs, environment: runEnv) }
            let second = try JSONDecoder().decode(JSONValue.self, from: out.stdout)
            guard second["udid"]?.string == leased, second["launched"]?.bool == true else {
                _ = try? await LeaseManager.release(second["udid"]?.string ?? leased, shutdown: true)
                await discard(leased)
                throw ShellError(command: "fast-ios run", status: out.status, stderr: "warm run did not reuse the booted simulator: \(out.text)")
            }
            times["fast-ios run (warm, same build)", default: []].append(warm)
            log("[app] fast-ios run (warm, same build) \(fmt(warm)) s")
            _ = try await LeaseManager.release(leased)

            // What an agent does after each code change: a new build of the
            // same app. A copy of the bundle with one extra file makes
            // `simctl install` copy and register it again (copying is not timed).
            log("[app] fast-ios run (warm, changed build)")
            let changedDir = FileManager.default.temporaryDirectory.appendingPathComponent("fast-ios-bench-build-\(UUID().uuidString.prefix(8))")
            let changed = changedDir.appendingPathComponent(appURL.lastPathComponent)
            try FileManager.default.createDirectory(at: changedDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: changedDir) }
            try FileManager.default.copyItem(at: appURL, to: changed)
            try Data(UUID().uuidString.utf8).write(to: changed.appendingPathComponent("fast-ios-bench-build-id.txt"))
            var changedArgs = runArgs
            if let i = changedArgs.firstIndex(of: "--app") { changedArgs[i + 1] = changed.path }
            note()
            let warmChanged = try await timed { out = try await Shell.run(o.fastIOSPath, changedArgs, environment: runEnv) }
            let third = try JSONDecoder().decode(JSONValue.self, from: out.stdout)
            let reused = third["udid"]?.string == leased && third["launched"]?.bool == true
            _ = try? await LeaseManager.release(third["udid"]?.string ?? leased, shutdown: true)
            await discard(leased)
            if let other = third["udid"]?.string, other != leased { await discard(other) }
            _ = try? await LeaseManager.list()  // forgets the deleted pool simulators
            guard reused else {
                throw ShellError(command: "fast-ios run", status: out.status, stderr: "changed-build run did not reuse the booted simulator: \(out.text)")
            }
            times["fast-ios run (warm, changed build)", default: []].append(warmChanged)
            log("[app] fast-ios run (warm, changed build) \(fmt(warmChanged)) s")

            // Cold again, with the pool empty, but cloning the slim template.
            log("[app] fast-ios run (cold, from template)")
            note()
            let fromTemplate = try await timed { out = try await Shell.run(o.fastIOSPath, runArgs, environment: templateEnv) }
            let fourth = try JSONDecoder().decode(JSONValue.self, from: out.stdout)
            let clonedUDID = fourth["udid"]?.string
            _ = try? await LeaseManager.release(clonedUDID ?? "", shutdown: true)
            if let clonedUDID { await discard(clonedUDID) }
            _ = try? await LeaseManager.list()
            guard fourth["cloned"]?.bool == true, fourth["launched"]?.bool == true else {
                throw ShellError(command: "fast-ios run", status: out.status, stderr: "template run did not clone the template: \(out.text)")
            }
            times["fast-ios run (cold, from template)", default: []].append(fromTemplate)
            log("[app] fast-ios run (cold, from template) \(fmt(fromTemplate)) s")
        }
        }
        do {
            try await appRounds()
        } catch {
            await Templates.remove(runtime: runtime, deviceType: deviceType, log: log)
            throw error
        }
        await Templates.remove(runtime: runtime, deviceType: deviceType, log: log)

        let steps: [String: String] = [
            "stock + simctl": "simctl create; simctl bootstatus -b; simctl install; simctl launch",
            "simslim + simctl": "simctl create; simslim on; simctl install; simctl launch",
            "fast-ios run (cold)": "fast-ios run --app <app> (empty pool: creates, slims, boots, installs, launches)",
            "fast-ios run (warm, same build)": "fast-ios run --app <app> after a release: reuses the booted slim simulator; the same bundle is installed again",
            "fast-ios run (warm, changed build)": "fast-ios run --app <new build> after a release: reuses the booted slim simulator; installs the changed bundle",
            "fast-ios run (cold, from template)": "fast-ios run --app <app> with an empty pool and a ready template: clones it, slims, boots, installs, launches",
            "fast-ios template build (once per runtime and device type)": "simctl create; full slim overrides; first boot; shutdown",
        ]
        let order = ["stock + simctl", "simslim + simctl", "fast-ios run (cold)", "fast-ios run (cold, from template)",
                     "fast-ios run (warm, same build)", "fast-ios run (warm, changed build)",
                     "fast-ios template build (once per runtime and device type)"]
        return (order.compactMap { m in
            times[m].map { BenchAppMethod(method: m, steps: steps[m] ?? "", seconds: round2(median($0)), samples: $0.map(round2)) }
        }, noisy)
    }

    // MARK: - What simslim has no command for

    static func capabilityRows(_ o: BenchOptions) async -> [BenchCapability] {
        var profileFact = "Reads Info.plist, entitlements and linked frameworks; pass --app to measure it."
        var measured = false
        if let app = o.app,
           let t = try? await timed({ try await Shell.run(o.fastIOSPath, ["profile", app, "--json"]) }),
           let out = try? await Shell.run(o.fastIOSPath, ["profile", app, "--json"]),
           let v = try? JSONDecoder().decode(JSONValue.self, from: out.stdout),
           let keep = v["profile"]?["keep"]?.object, let disable = v["profile"]?["disable"]?.array {
            profileFact = "Derived from the built app in \(fmt(t)) s: \(keep.count) services kept, \(disable.count) off, each kept one with its reason."
            measured = true
        }
        return [
            BenchCapability(name: "Profile from the built app",
                            fastIOS: profileFact,
                            simslim: "No app reading: a hand-written --profile JSON, or --except/--keep flags (simslim 0.14.0 help).",
                            measured: measured),
            BenchCapability(name: "Repair while the app runs",
                            fastIOS: "`fast-ios heal` sees the app fail to reach a service that is off and turns it on with no reboot, then saves it to the app's profile. Not timed by bench: it needs the app to call the service (see README, Self-repair).",
                            simslim: "`simslim enable <udid> <ids>` turns services on live, but you must know which ones.",
                            measured: false),
        ]
    }

    struct Sample {
        var slimCommand: String?
        var slim: Double?
        var firstReady: Double
        var cold: Double
        var processes = 0
        var bytes: Int64 = 0
        var disabled = 0
        var before: String
        var after: String
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s.isEmpty ? 0 : (s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2)
    }

    static func aggregate(_ variant: String, _ runs: [Sample]) -> BenchVariant {
        let first = runs[0]
        let slims = runs.compactMap(\.slim)
        let before = runs.map(\.before), after = runs.map(\.after)
        func worst(_ p: [String]) -> String {
            p.contains("critical") ? "critical" : p.contains("warning") ? "warning" : "normal"
        }
        return BenchVariant(
            variant: variant, slimCommand: first.slimCommand, slimSeconds: slims.isEmpty ? nil : round2(median(slims)),
            firstReadySeconds: round2(median(runs.map(\.firstReady))), coldBootSeconds: round2(median(runs.map(\.cold))),
            slimSamples: slims.map(round2), firstReadySamples: runs.map { round2($0.firstReady) },
            coldBootSamples: runs.map { round2($0.cold) }, runs: runs.count,
            processes: first.processes, memoryBytes: first.bytes, servicesDisabled: first.disabled,
            pressureBefore: worst(before), pressureAfter: worst(after),
            noisy: (before + after).contains { $0 != "normal" })
    }

    static func measureVariant(_ variant: String, udid: String, setPath: String, o: BenchOptions,
                               measureMemory: Bool, log: Log) async throws -> Sample {
        let before = MemoryStatus.read().pressure
        var slimCommand: String?
        var slimSeconds: Double?
        var firstReady: Double
        switch variant {
        case "stock":
            log("[stock] first boot")
            firstReady = try await timed { try await Simctl.bootAndWait(udid) }
        case "fast-ios":
            var args = ["slim", udid, "--set", setPath]
            args += o.app.map { ["--app", $0] } ?? ["--full"]
            slimCommand = "fast-ios " + args.joined(separator: " ").replacingOccurrences(of: setPath, with: "<set>")
            log("[fast-ios] \(slimCommand!)")
            let s = try await timed { try await Shell.run(o.fastIOSPath, args) }
            log("[fast-ios] first boot")
            let b = try await timed { try await Simctl.bootAndWait(udid) }
            slimSeconds = s; firstReady = s + b
        case "simslim":
            guard let simslim = o.simslimPath else { throw UsageError("simslim is not installed.") }
            let args = ["--set", setPath, "on", udid]
            slimCommand = "simslim --set <set> on \(udid)"
            log("[simslim] \(slimCommand!)")
            let s = try await timed { try await Shell.run(simslim, args) }
            slimSeconds = s; firstReady = s
            if try await Simctl.device(udid).isBooted == false {
                firstReady += try await timed { try await Simctl.bootAndWait(udid) }
            } else {
                try await Simctl.bootAndWait(udid)  // returns at once when ready
            }
        default:
            throw UsageError("Unknown bench variant \(variant). Use stock, fast-ios or simslim.")
        }
        log("[\(variant)] ready after \(fmt(firstReady)) s; shutting down for a cold boot")
        try await Simctl.shutdownAndWait(udid)
        let cold = try await timed { try await Simctl.bootAndWait(udid) }
        var sample = Sample(slimCommand: slimCommand, slim: slimSeconds, firstReady: firstReady, cold: cold,
                            before: before, after: MemoryStatus.read().pressure)
        guard measureMemory else {
            log("[\(variant)] cold boot \(fmt(cold)) s")
            return sample
        }
        log("[\(variant)] cold boot \(fmt(cold)) s; settling \(o.settleSeconds) s")
        try await Task.sleep(for: .seconds(o.settleSeconds))
        let procs = try await Measure.detailed(udid)
        sample.disabled = (try? await Simctl.printDisabled(udid))?.count ?? 0
        sample.after = MemoryStatus.read().pressure
        sample.processes = procs.count
        sample.bytes = procs.reduce(0) { $0 + $1.bytes }
        log("[\(variant)] \(procs.count) processes, \(sample.bytes / 1_048_576) MB, \(sample.disabled) disabled")
        return sample
    }

    static func discard(_ udid: String) async {
        _ = try? await Simctl.simctl("shutdown", udid, check: false)
        _ = try? await Simctl.simctl("delete", udid, check: false)
        try? FileManager.default.removeItem(at: DisabledStore.folder(udid))
        try? StateStore.update { $0.devices[udid] = nil }
    }

    static func timed(_ body: () async throws -> some Any) async throws -> Double {
        let start = ContinuousClock.now
        _ = try await body()
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    static func timeCommand(_ tool: String, _ path: String, _ args: [String], runs: Int, unsetSet: Bool = false) async throws -> BenchStartup {
        var times: [Double] = []
        for _ in 0..<max(1, runs) {
            times.append(try await timed { try await Shell.run(path, args, check: false, environment: unsetSet ? ["FASTIOS_DEVICE_SET": ""] : [:]) } * 1000)
        }
        times.sort()
        return BenchStartup(tool: tool, command: ([tool] + args).joined(separator: " "), runs: times.count,
                            medianMs: round2(times[times.count / 2]), minMs: round2(times[0]))
    }

    static func host() async -> BenchHost {
        func sysctlString(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            var buf = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname(name, &buf, &size, nil, 0)
            return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let macOS = (try? await Shell.run("/usr/bin/sw_vers", ["-productVersion"]))?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        let xcode = (try? await Shell.run("/usr/bin/xcrun", ["xcodebuild", "-version"]))?.text
            .split(separator: "\n").joined(separator: " ") ?? "?"
        return BenchHost(model: sysctlString("hw.model"), cpu: sysctlString("machdep.cpu.brand_string"),
                         memoryGB: MemoryStatus.read().totalMB / 1024, macOS: macOS, xcode: xcode)
    }

    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
    public static func fmt(_ x: Double) -> String { String(format: "%.1f", x) }
}
