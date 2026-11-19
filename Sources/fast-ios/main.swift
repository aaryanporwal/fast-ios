import FastIOSCore
import Foundation

let usage = """
fast-ios: lighter iOS simulators, with the services your app needs and nothing else.

USAGE
  fast-ios run [--app <app|folder>] [--url <url>] [--headless]
      Get a light simulator, install and open the app, show the Simulator
      window, print the UDID. With no --app, uses the newest simulator build
      of the project in this folder.
  fast-ios template [--build | --remove]
      Light templates that new pool simulators are copied from (skips first start).
  fast-ios pool --size N [--app <app|folder>]
      Keep N light simulators running and free, so the next run skips the start.
  fast-ios doctor
      Check Xcode, runtimes, memory and conflicting tools; a fix for each problem.
  fast-ios bench [--only full,fast-ios,simslim]
      Measure full vs fast-ios vs simslim on throwaway simulators.
  fast-ios profile <app|folder> [--keep <category|label>]... [--json]
      Show which services the app needs, and why. <folder> may be DerivedData,
      Build/Products, or your project folder (newest simulator .app wins).
  fast-ios slim <simulator> [--app <app|folder>] [--keep <category|label>]... [--full] [--boot]
      Make one simulator light for an app. A running simulator is restarted;
      a stopped one starts light next time. Without --app, uses the last app's
      light set, or --full (every service fast-ios knows off).
  fast-ios off [<simulator>] [--boot]
      Make simulators full again: remove every change fast-ios made.
  fast-ios uninstall [--dry-run]
      Remove every trace of fast-ios from this Mac.
  fast-ios status [--verbose]
      List simulators: running or not, light or full, memory of running ones.
  fast-ios measure <simulator>
      Process count and summed `footprint` memory of a running simulator.
  fast-ios watch [--app <app|folder>] [--full]
      Make each new simulator light before its first start. Runs until Ctrl-C.
  fast-ios catalog
      Every service fast-ios may disable, by category, with what breaks.
\(ShotCommand.usage)
  fast-ios mcp
      MCP server over stdio, for AI coding agents. Tools = the commands above.
  fast-ios completions <zsh|fish|bash>
      Print a shell completion script.

<simulator> is a UDID, a unique simulator name, or "booted".
Every command takes --set <path> for a custom CoreSimulator device set,
--json for machine-readable output (errors too), and --help.
Exit codes: 0 ok, 1 failed, 2 no simulator started (memory short or queue), 64 bad arguments.
"""

/// `--json` anywhere on the command line: JSON output, JSON errors.
let jsonMode = CommandLine.arguments.contains("--json")

struct Args {
    var positional: [String] = []
    var options: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        let valued: Set<String> = ["--app", "--keep", "--heal"]
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if valued.contains(a), i + 1 < raw.count {
                options[a, default: []].append(raw[i + 1]); i += 2
            } else if a.hasPrefix("--") {
                flags.insert(a); i += 1
            } else {
                positional.append(a); i += 1
            }
        }
    }
    func one(_ key: String) -> String? { options[key]?.last }
}

func fail(_ message: String) -> Never {
    let command = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") } ?? ""
    let hint = CLISpec.find(command) != nil ? " See `fast-ios \(command) --help`." : " See `fast-ios help`."
    let stop = message.last.map { ".?!".contains($0) } == true ? "" : "."
    fail(UsageError(message + stop + hint))
}

func fail(_ error: Error) -> Never {
    if jsonMode, let text = try? JSONOutput.encode(JSONOutput.error(error), pretty: true) {
        print(text)
        exit(ExitCode.of(error))
    }
    let message = (error as? ShellError).map { plainToolError($0) } ?? error.localizedDescription
    FileHandle.standardError.write(Data((styledError(message) + "\n").utf8))
    exit(ExitCode.of(error))
}

/// A failed `xcrun simctl …` in plain words: which step, Apple's own reason
/// without its error domain and code, and the next step. --verbose keeps all.
func plainToolError(_ e: ShellError) -> String {
    if verboseMode { return e.localizedDescription }
    let words = e.command.split(separator: " ").map(String.init)
    let step: String
    if let i = words.firstIndex(of: "simctl") {
        // Skip `--set <path>` to find the verb.
        var j = i + 1
        if j < words.count, words[j] == "--set" { j += 2 }
        step = j < words.count ? "`simctl \(words[j])`" : "`simctl`"
    } else {
        step = "`\(URL(fileURLWithPath: words.first ?? "").lastPathComponent)`"
    }
    var reason = e.stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .last { !$0.isEmpty && !$0.hasPrefix("Underlying error") } ?? ""
    reason = reason.replacingOccurrences(of: #"\s*\(domain=[^)]*\)"#, with: "", options: .regularExpression)
    let because = reason.isEmpty ? "" : ": \(reason)"
    return "Xcode's simulator tool could not finish \(step)\(because)\nNext: check the simulator and app you named (`fast-ios status`), then run `fast-ios doctor`. Add --verbose to see the full command."
}

func mb(_ bytes: Int64) -> String { "\(bytes / 1_048_576) MB" }

let log: Log = { print("  " + Style.dim($0)) }

func printProfile(_ profile: SlimProfile, matches: [CapabilityRule]) {
    print("Light set: \(profile.name)")
    let n = profile.keep.count
    if n == 0 {
        print(matches.isEmpty
              ? "The app needs none of the services fast-ios can turn off, so all \(ServiceCatalog.slimmable.count) are off. Keep one with --keep <category> (see `fast-ios catalog`)."
              : "Keeps no services: all \(ServiceCatalog.slimmable.count) are off.")
    } else {
        print("Keeps \(n) service\(n == 1 ? "" : "s") on:")
        for (label, reasons) in profile.keep.sorted(by: { $0.key < $1.key }) {
            print("  \(label)")
            for r in Set(reasons).sorted() { print("      ← \(r)") }
        }
        print("Turns off \(profile.disable.count) of \(ServiceCatalog.slimmable.count) services.")
    }
    print("Never turned off: \(NeverDisable.labels.keys.sorted().joined(separator: ", "))")
}

func resolveProfile(_ args: Args) async throws -> (SlimProfile, [CapabilityRule]) {
    try await FastIOSCommands.resolveProfile(app: args.one("--app"), keep: args.options["--keep"] ?? [],
                                             full: args.flags.contains("--full"), strict: args.flags.contains("--strict"))
}

func run() async throws {
    var raw = Array(CommandLine.arguments.dropFirst())
    // An unknown option stops everything before anything runs.
    if let bad = OptionCheck.firstUnknown(raw) {
        if bad.option.contains("="), let part = bad.option.split(separator: "=").first {
            let flag = String(part)
            let known = bad.command.isEmpty ? OptionCheck.global : (OptionCheck.accepted(bad.command) ?? OptionCheck.global)
            switch known[flag] {
            case false?: fail(UsageError("`\(flag)` takes no value: write just `\(flag)`. Nothing was changed."))
            case true?: fail(UsageError("Write `\(flag) <value>` with a space, not `\(bad.option)`. Nothing was changed."))
            case nil: break
            }
        }
        let message = bad.command.isEmpty
            ? "fast-ios has no option \(bad.option). Nothing was changed. See `fast-ios help`."
            : "fast-ios \(bad.command) has no option \(bad.option). Nothing was changed. See `fast-ios \(bad.command) --help` for its options."
        fail(UsageError(message))
    }
    // `--set <path>` picks a custom device set for every simctl call.
    if let i = raw.firstIndex(of: "--set"), i + 1 < raw.count {
        try Simctl.useDeviceSet(raw[i + 1])
        raw.removeSubrange(i...(i + 1))
    }
    let verbose = raw.contains("--verbose")
    raw.removeAll { $0 == "--verbose" || $0 == "--no-color" }  // read by Style at start-up
    if raw.first == "--version" || raw.first == "version" {
        if jsonMode {
            let v: JSONValue = ["schemaVersion": .int(Int64(JSONOutput.schemaVersion)), "version": .string(FastIOSVersion.current)]
            print(try JSONOutput.encode(v, pretty: true))
        } else {
            print("fast-ios \(FastIOSVersion.current)")
        }
        return
    }
    // Only a person at a terminal is welcomed; never the helper (its stderr is the log).
    if isPerson, !["mcp", "completions", "_agent"].contains(raw.first ?? "") { Welcome.showOnce() }
    // `fast-ios` alone is the product: a short status and the one next step.
    guard let command = raw.first, raw != ["--json"] else {
        if jsonMode {
            print(try JSONOutput.encode(try await MCPTools.named("status")!.call([:]), pretty: true))
        } else {
            try await Home.show(verbose: verbose)
        }
        return
    }
    let args = Args(Array(raw.dropFirst()))
    // `fast-ios <command> --help` and `fast-ios help <command>`.
    if let spec = CLISpec.find(command == "help" ? (raw.dropFirst().first ?? "") : command),
       command == "help" || args.flags.contains("--help") || raw.contains("-h") {
        print(CLISpec.help(spec)); return
    }
    // The two-word feature, the background helper, and help.
    switch command {
    case "on" where args.flags.contains("--dry-run"), "off" where args.flags.contains("--dry-run"):
        guard args.positional.isEmpty else {
            fail(UsageError("--dry-run works with `fast-ios on` and `fast-ios off` alone, not with a simulator. Nothing was changed."))
        }
        try await runSwitchDryRun(turningOn: command == "on")
        return
    case "on":
        if jsonMode {
            let r: AutoModeOnResult
            do { r = try await AutoMode.turnOn(cliAutoConfig()) } catch { failSwitch(error) }
            let v: JSONValue = ["schemaVersion": .int(Int64(JSONOutput.schemaVersion)), "on": true, "agentLabel": .string(r.agentLabel),
                                "alreadyOn": .bool(r.alreadyOn),
                                "madeLight": .array(r.madeLight.map { .string($0) }), "alreadyLight": .int(Int64(r.alreadyLight)),
                                "runningLeftAlone": .array(r.runningLeftAlone.map { .string($0) })]
            print(try JSONOutput.encode(v, pretty: true))
        } else {
            try await runOnCommand(verbose: verbose)
        }
        return
    case "off" where args.positional.isEmpty:
        if jsonMode {
            let r: AutoModeOffResult
            do { r = try await AutoMode.turnOff(cliAutoConfig()) } catch { failSwitch(error) }
            let v: JSONValue = ["schemaVersion": .int(Int64(JSONOutput.schemaVersion)), "on": false, "agentRemoved": .bool(r.agentRemoved),
                                "madeFull": .array(r.madeFull.map { .string($0) }),
                                "runningFullAfterRestart": .array(r.runningFullAfterRestart.map { .string($0) })]
            print(try JSONOutput.encode(v, pretty: true))
        } else {
            try await runOffAllCommand(verbose: verbose)
        }
        return
    case "_agent":
        await runAgentCommand()
        return
    case "uninstall" where !jsonMode:
        try await runUninstallCommand(dryRun: args.flags.contains("--dry-run"))
        return
    case "uninstall":
        fail(UsageError("uninstall has no --json output: run it in a terminal so you can read what it removes. Nothing was changed."))
    case "help", "--help", "-h":
        if !jsonMode { print(GroupedHelp.text); return }
    default: break
    }
    // heal streams events; its MCP tool is the bounded, all-at-once form.
    if command == "heal" {
        try await runHealCommand(Array(raw.dropFirst()), json: jsonMode)
        return
    }
    // Every command registered as an MCP tool prints that tool's JSON.
    if jsonMode, let tool = MCPTools.named(command) {
        // run and lease say on stderr while they wait for memory.
        let waitLog: Log? = ["run", "lease"].contains(command) ? stderrLog : nil
        let result = try await LeaseManager.$waitLog.withValue(waitLog) { try await tool.callFromCLI(Array(raw.dropFirst())) }
        print(try JSONOutput.encode(result, pretty: true))
        // A refused lease is an answer, not an error, but scripts need to tell.
        if result["status"]?.string == "refused" { exit(ExitCode.refused) }
        if result["ok"]?.bool == false { exit(ExitCode.failure) }
        return
    }

    switch command {
    case "run":
        try await runRunCommand(Array(raw.dropFirst()))
    case "apps":
        try await runAppsCommand(Array(raw.dropFirst()))
    case "bench":
        try await runBenchCommand(Array(raw.dropFirst()))
    case "doctor":
        exit(await runDoctorCommand())
    case "pool":
        try await runPoolCommand(Array(raw.dropFirst()))
    case "template":
        try await runTemplateCommand(Array(raw.dropFirst()))
    case "completions":
        guard let shell = args.positional.first else { fail("completions needs a shell: zsh, fish or bash") }
        print(try Completions.script(shell), terminator: "")

    case "mcp":
        try await MCPServer.run()

    case "profile":
        guard let path = args.positional.first else { fail("profile needs an app or folder") }
        let keep = try KeepNames.validate(args.options["--keep"] ?? [])
        let facts = try await AppInspector.inspect(try AppInspector.locateApp(path))
        let (profile, matches) = Profiler.derive(from: facts, keeping: keep)
        print("App: \(facts.appPath)")
        printProfile(profile, matches: matches)

    case "slim":
        guard let selector = args.positional.first else { fail("slim needs a simulator") }
        let device = try await Simctl.resolve(selector)
        let (profile, matches) = try await resolveProfile(args)
        if profile.appPath != nil, args.one("--app") != nil {
            printProfile(profile, matches: matches)
            try StateStore.update { $0.defaultProfile = profile }
        }
        print("Making \(device.name) (\(device.udid), \(device.runtimeName)) light with the light set \(profile.name)…")
        let result = try await Slimmer.slim(device, profile: profile, boot: args.flags.contains("--boot"), log: log)
        report(result, device: device)

    case "off":
        guard let selector = args.positional.first else { try await runOffAllCommand(verbose: verbose); return }
        let device = try await Simctl.resolve(selector)
        print("Making \(device.name) full again…")
        let result = try await Slimmer.restore(device, boot: args.flags.contains("--boot"), log: verbose ? log : { _ in })
        print(result.change.reenabled.isEmpty ? "\(device.name) was already full." : "\(device.name) is full again.")

    case "status":
        let devices = try await Simctl.listDevices().filter(\.isAvailable)
        let state = StateStore.load()
        let mem = await Measure.many(devices.filter(\.isBooted).map(\.udid))
        if devices.isEmpty { print(Style.code("No simulators yet. Create one in Xcode, or run `fast-ios run` in your app's folder.")) }
        for d in devices {
            let off = DisabledStore.disabledLabels(d.udid).intersection(ServiceCatalog.slimmable).count
            let light = Style.state(light: await LightState.isLight(d))
            let running = d.isBooted ? Style.bold("running") : Style.dim("stopped")
            let profile = verbose ? Style.dim(state.devices[d.udid]?.profileName ?? (off > 0 ? "set outside fast-ios" : "")) : ""
            let m = mem[d.udid].map { Style.bold(mb($0.bytes)) + (verbose ? ", \($0.processes) processes" : "") } ?? ""
            print([d.name, Style.dim(d.runtimeName), running, light, profile, m, verbose ? Style.dim(d.udid) : ""]
                .filter { !$0.isEmpty }.joined(separator: Style.dim(" · ")))
        }

    case "measure":
        guard let selector = args.positional.first else { fail("measure needs a simulator") }
        let device = try await Simctl.resolve(selector)
        let procs = try await Measure.detailed(device.udid)
        let total = procs.reduce(0) { $0 + $1.bytes }
        print("\(device.name) (\(device.udid)): \(procs.count) processes, \(mb(total)) summed footprint")
        for p in procs.prefix(15) { print("  \(mb(p.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(p.name) [\(p.pid)]") }

    case "watch":
        let (profile, _) = try await resolveProfile(args)
        let watcher = Simctl.deviceSet.map { DeviceSetWatcher(setFolders: [URL(fileURLWithPath: $0)]) } ?? DeviceSetWatcher()
        if let healApp = args.one("--heal") {
            Task { await healBootedSimulators(app: healApp, json: jsonMode) }
        }
        if jsonMode { await watchJSON(watcher, profile: profile); return }
        print("Watching \(watcher.setFolders.map(\.path).joined(separator: ", "))")
        print("New simulators get the light set \(profile.name) (\(profile.disable.count) services off) before their first start. Ctrl-C to stop.")
        await watcher.run { device in
            guard device.isShutdown else {
                print("\(device.udid): already starting; run `fast-ios slim \(device.udid)` to make it light.")
                return
            }
            do {
                let change = try DisabledStore.apply(device.udid, disable: profile.disableSet)
                try StateStore.record(device.udid, profile: profile)
                print("\(device.udid): made light before its first start (\(change.disabled.count) services off).")
            } catch {
                print("\(device.udid): could not make it light: \(error.localizedDescription)")
            }
        }

    case "shot":
        try await ShotCommand.run(Array(raw.dropFirst()))

    case "catalog":
        for c in ServiceCatalog.categories {
            print("\(c.name) [\(c.id)] ~\(c.approxMemoryMB) MB")
            print("  Off means: \(c.downside)")
            for l in c.labels { print("    \(l)  \(ServiceCatalog.descriptions[l] ?? "")") }
        }

    case "lease", "release", "leases":
        try await runLeaseCommand(command, Array(raw.dropFirst()))

    case "repairs":
        let r = try await MCPTools.named("repairs")!.callFromCLI(Array(raw.dropFirst()))
        let events = r["repairs"]?.array ?? []
        if events.isEmpty { print("No repairs yet.") }
        for e in events {
            let ms: Int64 = if case .int(let n)? = e["repairMs"] { n } else { 0 }
            print("\(e["time"]?.string ?? "") \(e["event"]?.string ?? "") \(e["label"]?.string ?? "") for \(e["bundleIdentifier"]?.string ?? "") in \(ms) ms")
        }
        for (app, labels) in r["learned"]?.object ?? [:] {
            print("Learned for \(app): \((labels.array ?? []).compactMap(\.string).joined(separator: ", "))")
        }

    case "help", "--help", "-h":
        let fullUsage = usage + "\n" + leaseUsage + "\n" + healUsage
        if jsonMode {
            let help: JSONValue = ["schemaVersion": .int(Int64(JSONOutput.schemaVersion)), "usage": .string(fullUsage),
                                   "jsonCommands": .array(MCPTools.all.map { .string($0.name) } + ["watch", "help", "bench"]),
                                   "helpCommands": .array(CLISpec.commands.map { .string($0.name) })]
            print(try JSONOutput.encode(help, pretty: true))
        } else {
            print(fullUsage)
        }

    default:
        let close = CLISpec.commands.map(\.name).filter { $0.hasPrefix(String(command.prefix(2))) }
        fail("unknown command \(command)" + (close.isEmpty ? "" : ". Did you mean \(close.joined(separator: " or "))?"))
    }
}

func report(_ result: SlimResult, device: SimDevice) {
    let c = result.change
    print("Changed: \(c.disabled.count) disabled, \(c.reenabled.count) re-enabled.")
    switch result.notHonoured {
    case nil: print("\(device.name) is stopped; it starts light next time.")
    case let missing? where missing.isEmpty: print("Booted and verified: launchd reports every override.")
    case let missing?: print("Booted, but \(missing.count) overrides are not active: \(missing.joined(separator: ", "))")
    }
}

/// `watch --json`: one WatchEvent per line.
func watchJSON(_ watcher: DeviceSetWatcher, profile: SlimProfile) async {
    @Sendable func emit(_ e: WatchEvent) { if let t = try? JSONOutput.encode(e, pretty: false) { print(t) } }
    emit(WatchEvent(event: "watching", setFolders: watcher.setFolders.map(\.path), profile: ProfileSummary(profile)))
    await watcher.run { device in
        guard device.isShutdown else {
            emit(WatchEvent(event: "skipped", udid: device.udid, message: "already starting; make it light with `fast-ios slim \(device.udid)`"))
            return
        }
        do {
            let change = try DisabledStore.apply(device.udid, disable: profile.disableSet)
            try StateStore.record(device.udid, profile: profile)
            emit(WatchEvent(event: "slimmed", udid: device.udid, disabledCount: change.disabled.count))
        } catch {
            emit(WatchEvent(event: "error", udid: device.udid, message: error.localizedDescription))
        }
    }
}

// Line-buffer stdout so `watch` output reaches a log file or pipe at once.
setvbuf(stdout, nil, _IOLBF, 0)
do {
    try await run()
} catch {
    fail(error)
}
