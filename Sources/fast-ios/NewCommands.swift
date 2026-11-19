import FastIOSCore
import Foundation

// Human output for bench, run, doctor and completions. With --json, run and
// doctor go through their MCP tools in main.swift; bench prints its own JSON.

/// Exit codes, the same for every command.
enum ExitCode {
    static let ok: Int32 = 0
    /// The command ran and failed (a simulator, app or tool error).
    static let failure: Int32 = 1
    /// No simulator was started: memory is short, or others' starts ran past the wait.
    static let refused: Int32 = 2
    /// Bad arguments: unknown option, missing value or argument (EX_USAGE).
    static let usage: Int32 = 64

    static func of(_ error: Error) -> Int32 {
        switch error {
        case is UsageError, is InvalidArguments: usage
        case is LeaseRefusal: refused
        default: failure
        }
    }
}

/// Values for options that take one (`--name value`), from raw words.
struct Flags {
    let words: [String]
    func value(_ name: String) -> String? {
        guard let i = words.lastIndex(of: name) else { return nil }
        return i + 1 < words.count ? words[i + 1] : nil
    }
    func has(_ name: String) -> Bool { words.contains(name) }

    /// Rejects options the command does not have, and options missing their value.
    func check(against command: String) throws {
        guard let spec = CLISpec.find(command) else { return }
        let options = spec.options + CLISpec.global
        var i = 0
        while i < words.count {
            let w = words[i]; i += 1
            guard w.hasPrefix("--") else { continue }
            guard let o = options.first(where: { $0.flag == w }) else {
                throw UsageError("\(command) has no option \(w). See `fast-ios \(command) --help`.")
            }
            if let v = o.value {
                guard i < words.count, !words[i].hasPrefix("--") else {
                    throw UsageError("\(w) needs a value (<\(v)>). See `fast-ios \(command) --help`.")
                }
                i += 1
            }
        }
    }
}

/// A person at a terminal (not `--json`, stderr is a terminal): shorter
/// waits, a Simulator window after `run`, plain progress lines.
let isPerson = !jsonMode && isatty(STDERR_FILENO) != 0
let verboseMode = CommandLine.arguments.contains("--verbose")

/// `run`'s progress for a person: file paths and counts only with --verbose.
enum RunProgress {
    static func plain(_ line: String) -> String? {
        let detail = ["Wrote ", "attempt ", "Building a light template", "not building a template"]
        return detail.contains { line.hasPrefix($0) } ? nil : line
    }
}

let stderrLog: Log = {
    FileHandle.standardError.write(Data((Style.dim("fast-ios:", to: Style.err) + " " + Style.code($0, to: Style.err) + "\n").utf8))
}

func runBenchCommand(_ words: [String]) async throws {
    let f = Flags(words: words)
    try f.check(against: "bench")
    guard let me = Bundle.main.executablePath else { throw UsageError("Cannot find the fast-ios binary path.") }
    var o = BenchOptions(fastIOSPath: me)
    // `--only startup` measures CLI start-up alone, with no simulator.
    // "full" is the word people read; "stock" stays the variant's ID in JSON.
    if let only = f.value("--only") {
        o.variants = only.split(separator: ",").map { $0 == "full" ? "stock" : String($0) }.filter { $0 != "startup" }
    }
    if let s = f.value("--settle") {
        guard let n = Int(s), n >= 0 else { throw UsageError("--settle needs a number of seconds, e.g. --settle 180.") }
        o.settleSeconds = n
    }
    if let r = f.value("--runs") {
        guard let n = Int(r), n > 0 else { throw UsageError("--runs needs a positive number, e.g. --runs 10.") }
        o.startupRuns = n
    }
    if let r = f.value("--repeat") {
        guard let n = Int(r), n > 0 else { throw UsageError("--repeat needs a positive number, e.g. --repeat 3.") }
        o.repeats = n
    }
    if let s = f.value("--scenario") {
        guard ["boot", "app", "all", "parallel", "shot", "build"].contains(s) else {
            throw UsageError("--scenario takes boot, app, all, parallel, shot or build; got \(s).")
        }
        o.scenario = s
    }
    if o.scenario == "build" {
        try await runBuildBench(f)
        return
    }
    if let a = f.value("--agents") {
        guard let n = Int(a), (1...16).contains(n) else { throw UsageError("--agents needs a number from 1 to 16, e.g. --agents 3.") }
        o.agents = n
    }
    o.injectFault = f.has("--inject-fault")
    o.app = f.value("--app")
    o.runtime = f.value("--runtime")
    o.deviceType = f.value("--device-type")
    o.simslimPath = f.value("--simslim") ?? findOnPath("simslim")
    let result = try await Bench.run(o, log: stderrLog)
    if jsonMode { print(try JSONOutput.encode(result, pretty: true)); return }
    printBench(result)
}

func findOnPath(_ name: String) -> String? {
    let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") + ["/opt/homebrew/bin", "/usr/local/bin"]
    return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

func printBench(_ r: BenchOutput) {
    print(Style.accent("fast-ios bench") + Style.dim(" · \(r.date) · \(r.host.model) \(r.host.cpu), \(r.host.memoryGB) GB, macOS \(r.host.macOS), \(r.host.xcode)"))
    print(Style.dim("\(r.deviceType) on \(r.runtime); fast-ios profile: \(r.fastIOSProfile)\(r.simslimVersion.map { "; \($0)" } ?? "")"))
    print("")
    if !r.variants.isEmpty { printVariants(r) }
    if !r.app.isEmpty {
        print(Style.bold("Time to the app running") + Style.dim(" (create to `simctl launch` returned; median of \(r.app.first?.samples.count ?? 0))"))
        for m in r.app {
            let runs = m.samples.map { String(format: "%.1f", $0) }.joined(separator: " / ")
            print("  " + m.method.padding(toLength: 36, withPad: " ", startingAt: 0) + "\(Bench.fmt(m.seconds)) s".leftPad(9) + "   runs: \(runs)")
        }
        print("")
    }
    if !r.shot.isEmpty {
        let runs = r.shot.first?.samplesMs.count ?? 0
        print(Style.bold("Shot") + Style.dim(" (median of \(runs) run\(runs == 1 ? "" : "s"); app already installed)"))
        print("  " + "".padding(toLength: 38, withPad: " ", startingAt: 0) + "total".leftPad(9) + "tree".leftPad(9) + "screen".leftPad(9) + "PNG".leftPad(14))
        func s(_ ms: Int?) -> String { ms.map { String(format: "%.1f s", Double($0) / 1000) } ?? "-" }
        for row in r.shot {
            let png = "\(row.screenshotWidth) px \(row.screenshotBytes / 1024) KB"
            print("  " + row.name.padding(toLength: 38, withPad: " ", startingAt: 0) + s(row.totalMs).leftPad(9)
                  + s(row.treeMs).leftPad(9) + s(row.screenMs).leftPad(9) + png.leftPad(14))
        }
        print("")
    }
    if !r.parallel.isEmpty {
        print(Style.bold("\(r.parallel[0].agents) agents calling `fast-ios run` at once"))
        for (i, p) in r.parallel.enumerated() {
            print("  round \(i + 1): \(p.succeeded)/\(p.agents) launched, \(p.retries) simulator(s) replaced, wall \(Bench.fmt(p.wallSeconds)) s, agents \(p.agentSeconds.map { String(format: "%.0f", $0) }.joined(separator: "/")) s, lowest available \(p.minAvailableMB) MB, worst pressure \(p.worstPressure)")
            for e in p.errors { print("    " + Style.bad("error:") + " \(e)") }
            for rep in p.replaced { print("    replaced \(rep.udid): \(rep.reason) (\(rep.deleted ? "deleted" : "dropped from the pool"))") }
        }
        print("")
    }
    for c in r.capabilities {
        print("\(Style.bold(c.name))\n  \(Style.accent("fast-ios:")) \(c.fastIOS)\n  \(Style.dim("simslim: ")) \(c.simslim)")
    }
    if !r.capabilities.isEmpty { print("") }
    func notes() {
        for n in r.notes { print(Style.caution("Note:") + " \(n)") }
        if r.noisy { print(Style.bad("NOISY:") + " memory pressure was not normal. Do not publish these numbers.") }
    }
    if r.startup.isEmpty { notes(); return }
    print(Style.bold("CLI start-up") + Style.dim(" (median of \(r.startup.first?.runs ?? 0) runs)"))
    for s in r.startup {
        print("  " + s.command.padding(toLength: 28, withPad: " ", startingAt: 0) + "\(Bench.fmt(s.medianMs)) ms".leftPad(10) + "  (min \(Bench.fmt(s.minMs)) ms)")
    }
    notes()
}

func printVariants(_ r: BenchOutput) {
    let cols = r.variants.map(\.variant)
    func row(_ label: String, _ values: [String], header: Bool = false) {
        // Pad first, colour after, so escape codes never break the columns.
        let padded = values.map { $0.leftPad(12) }
        let cells = header ? padded.map { Style.bold($0) }.joined()
            : zip(cols, padded).map { $0 == "fast-ios" ? Style.accent($1) : $1 }.joined()
        print(Style.dim(label.padding(toLength: 30, withPad: " ", startingAt: 0)) + cells)
    }
    func secs(_ x: Double?) -> String { x.map { "\(Bench.fmt($0)) s" } ?? "n/a" }
    let runs = r.variants.map(\.runs).max() ?? 1
    row(runs > 1 ? "(timings: median of \(runs) runs)" : "", cols.map { $0 == "stock" ? "full" : $0 }, header: true)
    row("Make-light command", r.variants.map { secs($0.slimSeconds) })
    row("Fresh simulator to ready", r.variants.map { secs($0.firstReadySeconds) })
    row("Cold boot to ready", r.variants.map { secs($0.coldBootSeconds) })
    if runs > 1 {
        row("  fresh-to-ready runs", r.variants.map { $0.firstReadySamples.map { String(format: "%.0f", $0) }.joined(separator: "/") })
    }
    row("Processes after \(r.settleSeconds) s", r.variants.map { "\($0.processes)" })
    row("Memory after \(r.settleSeconds) s", r.variants.map { "\($0.memoryBytes / 1_048_576) MB" })
    row("Services disabled", r.variants.map { "\($0.servicesDisabled)" })
    row("Memory pressure", r.variants.map { $0.pressureBefore == $0.pressureAfter ? $0.pressureBefore : "\($0.pressureBefore)→\($0.pressureAfter)" })
    print("")
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? " " + self : String(repeating: " ", count: n - count) + self }
}

func runRunCommand(_ words: [String]) async throws {
    let f = Flags(words: words)
    try f.check(against: "run")
    var r = RunRequest()
    if let p = f.value("--max-pressure") {
        guard ["normal", "warning"].contains(p) else { throw UsageError("--max-pressure takes normal or warning; got \(p).") }
        r.policy = AdmissionPolicy(maxPressure: p)
    }
    // --timeout is the old name of --wait-for-memory.
    if let t = f.value("--wait-for-memory") ?? f.value("--timeout") {
        guard let v = FastIOSCommands.parseDuration(t), v >= 0 else { throw UsageError("--wait-for-memory needs a duration such as 90s, 5m or 1h; got \(t).") }
        r.memoryWait = v
    }
    r.keep = try KeepNames.validate(words.indices.filter { words[$0] == "--keep" && $0 + 1 < words.count }.map { words[$0 + 1] })
    r.app = f.value("--app")
    r.url = f.value("--url")
    r.grant = try Privacy.validate(words.indices.filter { words[$0] == "--grant" && $0 + 1 < words.count }.map { words[$0 + 1] })
    r.runtime = f.value("--runtime")
    r.deviceType = f.value("--device-type")
    r.simulator = f.value("--simulator")
    r.launch = !f.has("--no-launch")
    r.cache = try cacheRequest(value: f.value)
    if let ttl = f.value("--ttl") {
        guard let t = FastIOSCommands.parseDuration(ttl) else { throw UsageError("--ttl needs a duration such as 90s, 30m or 2h; got \(ttl).") }
        r.ttl = t
    }
    // A person sees the steps in plain words; --verbose adds the details.
    let plainLog: Log = { line in
        if let plain = RunProgress.plain(line) { stderrLog(plain) }
    }
    let out = try await AppRunner.run(r, log: verboseMode ? stderrLog : plainLog)
    let app = URL(fileURLWithPath: out.app).deletingPathExtension().lastPathComponent
    let what = out.launched ? "Opened \(app)" : "Installed \(app)"
    let wait = out.seconds.waited >= 1 ? ", \(Bench.fmt(out.seconds.waited)) s of it waiting for memory" : ""
    stderrLog("\(what) on \(out.name), a light simulator, in \(Bench.fmt(out.seconds.total)) s\(wait).")
    // Show it, unless nobody is watching (pipe, --json) or --headless.
    if out.launched, isPerson, !f.has("--headless") {
        switch await SimulatorWindow.show(udid: out.udid, name: out.name) {
        case .opened(let text): stderrLog(text + " Pass --headless to skip the window.")
        case .notPossible(let text): stderrLog(text)
        }
    }
    if out.simulatorSource == "leased" { stderrLog("When you are done: `fast-ios release \(out.udid)`.") }
    print(out.udid)  // stdout is the UDID alone, for UDID=$(fast-ios run)
}

/// The pool, for `pool`, `leases` and `fast-ios`: what was just shut down, then one line each.
func printPool(_ shutDown: [PoolTrim.Decision], _ status: [String]) {
    for d in shutDown {
        let why = switch d.reason {
        case .memory: "memory was short"
        case .idle: "nobody used it for the idle limit"
        case .overSize: "more were warm than the warm size"
        }
        print("Shut down free pool simulator \(d.udid): \(why).")
    }
    if status.isEmpty { return }
    print("Pool (simulators fast-ios made for `run` and `lease`):")
    for line in status { print("  " + line) }
}

func runPoolCommand(_ words: [String]) async throws {
    let f = Flags(words: words)
    try f.check(against: "pool")
    guard let size = f.value("--size") else {
        if let idle = f.value("--idle") {
            guard let v = FastIOSCommands.parseDuration(idle), v >= 60 else { throw UsageError("--idle needs at least 1m, such as 30m or 2h; got \(idle).") }
            var c = PoolConfig.load()
            c.idleMinutes = Int(v / 60)
            try c.save()
        }
        let l = try await LeaseManager.list()
        print("Warm size \(LeaseManager.warmSize); a free running one is shut down after \(LeaseManager.duration(PoolTrim.idleLimit)), or at once while memory is short. Change them with `fast-ios pool --size N` and `--idle 30m`.")
        printPool(l.shutDown, l.poolStatus)
        return
    }
    guard Int(size) != nil else { throw UsageError("--size needs a whole number, e.g. --size 1.") }
    let out = try await MCPTools.named("pool")!.callFromCLI(words)
    let free = out["free"]?.array?.compactMap(\.string) ?? []
    print("Warm size \(size): \(free.count) free booted simulator(s)\(free.isEmpty ? "" : ": " + free.joined(separator: ", ")).")
    if let why = out["shortBecause"]?.string { print("Short of \(size) because \(why).") }
}

func runDoctorCommand() async -> Int32 {
    let d = await Doctor.run(switchConfig: cliAutoConfig())
    for c in d.checks {
        // The word stays ("ok", "warn", "FAIL"); colour only adds to it.
        let mark = switch c.status {
        case "ok": Style.good("ok  ")
        case "warn": Style.caution("warn")
        default: Style.bad("FAIL")
        }
        print("\(mark)  \(Style.bold(c.id)): \(Style.code(c.summary))")
        if let fix = c.fix { print("      \(Style.dim("fix:")) \(Style.code(fix))") }
    }
    if !d.ok {
        print("\n" + Style.bad("Fix the FAIL lines first."))
    } else if !d.canStartSimulator {
        print("\n" + Style.caution("fast-ios is set up, but a new simulator cannot start right now.") + " "
              + Style.code("Simulators that are already running still work. See the memory line above."))
    } else {
        print("\n" + Style.good("fast-ios can run here, and a new simulator can start now."))
    }
    return d.ok ? ExitCode.ok : ExitCode.failure
}
