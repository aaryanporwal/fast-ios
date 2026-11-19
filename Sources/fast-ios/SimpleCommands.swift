import FastIOSCore
import Foundation

enum FastIOSVersion {
    static let current = "0.4.1"
}

/// Shown once, the first time any command runs.
enum Welcome {
    static var marker: URL { StateStore.url.deletingLastPathComponent().appendingPathComponent("welcomed") }

    static func showOnce() {
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        FileHandle.standardError.write(Data("""
        Welcome to fast-ios. It makes iOS simulators light: it turns off background services an app does not need, so a simulator needs about a third of the memory.
        To keep every simulator light from now on, run: fast-ios on

        """.utf8))
    }
}

/// `fast-ios` with no arguments.
enum Home {
    static func show(verbose: Bool) async throws {
        let devices = try await Simctl.listDevices().filter(\.isAvailable)
        let running = devices.filter(\.isBooted)
        let mem = await Measure.many(running.map(\.udid))
        let config = cliAutoConfig()
        let status = await AutoMode.status(config)
        let others = status.conflictBlocksTurningOn ? status.conflictingAgents : []
        // Light from the real state (running ones ask their launchd), the same rule `on` uses.
        var lightUDIDs = Set<String>()
        for d in devices where await LightState.isLight(d) { lightUDIDs.insert(d.udid) }
        func isLight(_ d: SimDevice) -> Bool { lightUDIDs.contains(d.udid) }

        print(Style.accent("fast-ios") + " " + Style.dim(FastIOSVersion.current))
        let otherRunning = status.otherFastIOSAgents.filter(\.loaded)
        let automatic = Style.bold("Automatic:")
        if status.isOn && !status.agentLoaded {
            print("\(automatic) \(Style.caution("on, but its background helper is not running")). " + Style.code("Run `fast-ios on` again."))
        } else if status.isOn {
            print("\(automatic) \(Style.good("on")). Every simulator stays light.")
            print(Style.dim(howLightWorks))
            if let last = HelperLog.lastAction(config.logFile, devices: devices) { print(Style.dim(last)) }
        } else if let other = otherRunning.first(where: { $0.deviceSet == Simctl.deviceSet }) {
            // Only a helper for these same simulators matters here; one for
            // another device set does not keep these light.
            let scope = other.deviceSet.map { "the simulators in \($0)" } ?? "your normal simulators"
            print("\(automatic) \(Style.caution("off")) here, but another fast-ios helper is running and keeps \(scope) light" + (verbose ? " (\(other.label))." : "."))
        } else {
            print("\(automatic) \(Style.caution("off")).")
        }
        let lightCount = devices.filter(isLight).count
        print("\(Style.bold("Simulators:")) \(devices.count), \(Style.good("\(lightCount) light")), \(running.count) running.")
        // "Saved" and each full size come from Savings, the same rule the
        // menu-bar app uses; really-full simulators are measured on the way.
        let ages = await Measure.bootAge(running.map(\.udid))
        let state = StateStore.load()
        var observations: [String: Savings.Observation] = [:]
        for d in running {
            observations[d.udid] = Savings.Observation(d, diskDisabled: DisabledStore.disabledLabels(d.udid),
                                                       liveDisabled: await LightState.liveDisabled(d.udid),
                                                       measurement: mem[d.udid], bootAge: ages[d.udid], state: state)
        }
        var store = BaselineStore.load()
        if store.record(Array(observations.values)) { try? store.save() }
        let savings = running.compactMap { d in observations[d.udid].flatMap { Savings.saving(for: $0, store: store) } }
        let nameWidth = min(28, running.map { "\($0.name) (\($0.runtimeName))".count }.max() ?? 0)
        for d in running {
            let used = mem[d.udid].map { Int($0.bytes / 1_048_576) }
            let light = isLight(d)
            let name = "\(d.name) (\(d.runtimeName))"
            if Style.out == .none {
                print("  \(name) is running \(light ? "light" : "full")\(used.map { ", using \($0) MB" } ?? "")")
            } else {
                // Coloured: aligned columns and a bar of its memory against a full simulator's.
                let padded = name.padding(toLength: max(nameWidth, name.count), withPad: " ", startingAt: 0)
                let state = light ? "light" : "full"
                // Visible width so far, so the bar shrinks (or goes) to fit the terminal.
                let prefix = 2 + padded.count + 13 + state.count + 1 + (used == nil ? 0 : 15)
                let room = (Style.terminalWidth ?? 100) - prefix - 3
                let full = observations[d.udid].map { store.baseline(udid: d.udid, runtime: $0.runtime, deviceType: $0.deviceType) }
                let fullMB = Int((full?.bytes ?? Savings.estimatedFullBytes) / 1_048_576)
                let memory = used.map { mbUsed -> String in
                    let bar = room >= 8 ? "  " + Style.bar(used: mbUsed, of: fullMB, width: min(20, room), light: light) : ""
                    return " using \(Style.bold(String(format: "%5d MB", mbUsed)))\(bar)"
                } ?? ""
                print("  \(padded)  is running \(Style.state(light: light)),\(memory)")
            }
            if !status.isOn, observations[d.udid]?.startedBeforeMadeFull() == true {
                print(Style.dim("    Still light until its next start: fast-ios was turned off while it ran."))
            }
        }
        if let total = Savings.total(savings), total.saved > 0 {
            print(savingLine(total))
        }
        // What the pool holds and why (display only; `fast-ios leases` also trims it).
        let pool = LeaseStore.poolStatus(booted: Set(running.map(\.udid)))
        if !pool.isEmpty {
            print(Style.bold("Pool:") + " " + Style.dim("simulators fast-ios made for `run` and `lease`"))
            for line in pool { print("  " + Style.dim(line)) }
        }
        if verbose {
            print(Style.dim("Helper: \(status.agentLabel) (\(tilde(status.plistPath))), \(status.agentLoaded ? "loaded" : "not loaded"), log \(tilde(config.logFile.path))"))
            if let set = Simctl.deviceSet { print(Style.dim("Device set: \(set)")) }
        }
        if !others.isEmpty {
            print(Style.caution("Note:") + " " + Style.code("simslim is also making simulators light on this Mac. Run `fast-ios doctor` before `fast-ios on`."))
        }
        print("")
        print(Style.bold("Next:") + " " + Style.code(nextStep(isOn: status.isOn, devices: devices, running: running, isLight: isLight)))
    }

    /// "Saving about 2.1 GB compared with a full simulator (estimated: …)."
    static func savingLine(_ t: Savings.Total) -> String {
        let amount = "about \(String(format: "%.1f", Double(t.saved) / 1_073_741_824)) GB"
        let compared = t.count == 1 ? "a full simulator" : "\(t.count) full simulators"
        let basis: String = switch t.source {
        case .measured: "measured on this Mac when it ran full"
        case .sameModel: "measured on this Mac with the same model running full"
        case .estimated: "an estimate: the full size is \(Savings.estimateDescription)"
        }
        var line = "Saving \(Style.accent(amount)) compared with \(compared) (\(basis))."
        if t.settling { line += " " + Style.dim("Too early to be sure: memory climbs for about 3 minutes after a start, so the saving will shrink a little.") }
        return line
    }

    static func nextStep(isOn: Bool, devices: [SimDevice], running: [SimDevice], isLight: (SimDevice) -> Bool) -> String {
        if !isOn { return "run `fast-ios on` to keep every simulator light." }
        if devices.isEmpty { return "create a simulator in Xcode, or run `fast-ios run` in your app's folder." }
        if let full = running.first(where: { !isLight($0) }) {
            return "\(full.name) is running full. Quit it in Simulator and start it again to make it light."
        }
        if running.isEmpty { return "start a simulator as usual (Xcode, or `fast-ios run` in your app's folder). It starts light." }
        return "nothing to do. `fast-ios help` lists everything else."
    }
}

/// How "light" relates to an app, in one sentence (`fast-ios` and `fast-ios on`).
var howLightWorks: String {
    let general = AutoMode.generalProfile()
    return "Until fast-ios knows your app, a simulator gets the general light set (\(general.disable.count) of \(ServiceCatalog.slimmable.count) services off); `fast-ios run` adds what your app needs, and a service comes back on by itself when an app needs it."
}

/// A path with the home folder shown as `~`, so output that people paste or
/// record never carries their user name.
func tilde(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// The helper's latest action, from its log, so a person can see it works.
enum HelperLog {
    static func lastAction(_ log: URL, devices: [SimDevice]) -> String? {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        let names = Dictionary(devices.map { ($0.udid, $0.name) }, uniquingKeysWith: { a, _ in a })
        // Lines are "<ISO date> <udid>: <what happened>"; only ones about these simulators.
        for line in text.split(separator: "\n").reversed() {
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count == 3, let date = ISO8601DateFormatter().date(from: String(parts[0])) else { continue }
            let udid = String(parts[1].dropLast())
            guard parts[1].hasSuffix(":"), let name = names[udid] else { continue }
            let when = date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
            return "Last helper action, \(when): \(name): \(parts[2]) (from \(tilde(log.path)))."
        }
        return nil
    }
}

/// The CLI's switch config: this program's own path, `--set`, and
/// `FASTIOS_AGENT_LABEL` for tests.
func cliAutoConfig() -> AutoModeConfig {
    // Not `CommandLine.arguments[0]`: run from PATH that is the bare word
    // "fast-ios", which would resolve against the current folder.
    let own = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let exe = URL(fileURLWithPath: own).standardizedFileURL.resolvingSymlinksInPath().path
    return AutoModeConfig.fromEnvironment(executablePath: exe)
}

/// A switch error in plain words: what happened, then the next step.
func failSwitch(_ e: AutoModeError) -> Never {
    if jsonMode {
        let v: JSONValue = ["schemaVersion": .int(Int64(JSONOutput.schemaVersion)),
                            "error": ["code": .string(e.kind.rawValue), "message": .string(e.message), "nextStep": .string(e.nextStep)]]
        print((try? JSONOutput.encode(v, pretty: true)) ?? "")
    } else {
        print(Style.bad("Stopped:") + " " + e.message)
        print(Style.bold("Next:") + " " + Style.code(e.nextStep))
    }
    exit(ExitCode.failure)
}

func runOnCommand(verbose: Bool) async throws {
    let config = cliAutoConfig()
    let r: AutoModeOnResult
    do { r = try await AutoMode.turnOn(config) } catch { failSwitch(error) }
    let total = r.madeLight.count + r.alreadyLight
    let count = Style.good("\(total) simulator\(total == 1 ? " is" : "s are") light")
    if r.alreadyOn {
        print("fast-ios is \(Style.good("already on")). Nothing was changed: \(count).")
    } else {
        print("fast-ios is \(Style.good("on")): \(count) now, and new ones will be light from their first start.")
    }
    print(howLightWorks)
    if !r.runningLeftAlone.isEmpty {
        let names = r.runningLeftAlone.joined(separator: ", ")
        print("\(r.runningLeftAlone.count) running simulator\(r.runningLeftAlone.count == 1 ? "" : "s") (\(names)) become\(r.runningLeftAlone.count == 1 ? "s" : "") light the next time \(r.runningLeftAlone.count == 1 ? "it starts" : "they start").")
    }
    if verbose {
        print("Helper \(r.agentLabel) installed at \(tilde(config.plistURL.path)); log \(tilde(config.logFile.path)).")
    }
}

func runOffAllCommand(verbose: Bool) async throws {
    let config = cliAutoConfig()
    let wasOn = FileManager.default.fileExists(atPath: config.plistURL.path)
    let r: AutoModeOffResult
    do { r = try await AutoMode.turnOff(config) } catch { failSwitch(error) }
    let changed = r.madeFull.count + r.runningFullAfterRestart.count
    if !wasOn && changed == 0 {
        print("fast-ios was already off. Nothing changed.")
    } else {
        var parts = ["its background helper no longer runs"]
        let full = r.madeFull.count, later = r.runningFullAfterRestart.count
        if full > 0 { parts.append("\(Style.bold("\(full) stopped simulator\(full == 1 ? " is" : "s are")")) full again") }
        if later > 0 { parts.append("\(later) running simulator\(later == 1 ? " becomes" : "s become") full at \(later == 1 ? "its" : "their") next start") }
        let joined = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
        print("fast-ios is \(Style.caution("off")): \(joined).")
        if r.agentRemoved { print("Removed: the background helper \(config.label) (\(tilde(config.plistURL.path))).") }
        if !r.madeFull.isEmpty { print("Made full: \(r.madeFull.joined(separator: ", ")).") }
    }
    try await printLeftovers(config, stillLight: r.runningFullAfterRestart)
}

/// What is still on this Mac after `off`, and the one way to remove it all.
func printLeftovers(_ config: AutoModeConfig, stillLight: [String]) async throws {
    var left: [String] = []
    if !stillLight.isEmpty {
        let names = stillLight.joined(separator: ", ")
        left.append("\(names) \(stillLight.count == 1 ? "is" : "are") still light in memory until \(stillLight.count == 1 ? "its" : "their") next start (quit and start \(stillLight.count == 1 ? "it" : "them") again to be full now).")
    }
    for item in await Leftovers.find(config) where item.kind != .helper {
        left.append(item.path.isEmpty ? "\(item.what)." : "\(item.what): \(item.path)")
    }
    if left.isEmpty { print("Nothing of fast-ios is left on this Mac."); return }
    print("Still here:")
    for l in left { print("  " + l) }
    print(Style.bold("Next:") + " " + Style.code("nothing, if you may use fast-ios again. To remove every trace: `fast-ios uninstall`."))
}

/// `fast-ios uninstall`: off, then delete fast-ios's own files, then say
/// exactly what is left for the person to remove (the app, the command link).
func runUninstallCommand(dryRun: Bool) async throws {
    let config = cliAutoConfig()
    let before = await Leftovers.find(config)
    if dryRun {
        print(Style.bold("Dry run:") + " " + Style.dim("nothing was changed."))
        print("fast-ios uninstall would run `fast-ios off`, then delete:")
        for i in before where i.removable { print("  \(i.what): \(i.path)") }
        let manual = before.filter { !$0.removable }
        if !manual.isEmpty {
            print("You would remove these yourself:")
            for i in manual { print("  \(i.what)\(i.path.isEmpty ? "" : " (\(i.path))"): \(i.howToRemove ?? "")") }
        }
        return
    }
    let r: AutoModeOffResult
    do { r = try await AutoMode.turnOff(config) } catch { failSwitch(error) }
    print("fast-ios is \(Style.caution("off"))\(r.agentRemoved ? ": removed the background helper \(config.label)" : "").")
    let (removed, failed) = Leftovers.removeFiles(await Leftovers.find(config))
    for i in removed { print("Removed \(i.what): \(i.path)") }
    for (i, why) in failed { print(Style.bad("Could not remove") + " \(i.path): \(why)") }
    if !r.runningFullAfterRestart.isEmpty {
        print("\(r.runningFullAfterRestart.joined(separator: ", ")) still run light in memory until their next start; nothing is stored for them any more.")
    }
    let manual = await Leftovers.find(config)
    if manual.isEmpty {
        print(Style.good("Every trace of fast-ios is gone from this Mac."))
    } else {
        print("Left for you to remove:")
        for i in manual { print("  \(i.what)\(i.path.isEmpty ? "" : " (\(i.path))"): \(i.howToRemove ?? "delete it")") }
    }
    if !failed.isEmpty { exit(ExitCode.failure) }
}

func runAgentCommand() async {
    await AutoMode.runAgent { print("\(Date().ISO8601Format()) \($0)") }
}

enum GroupedHelp {
    static let everyday = ["on", "off", "status", "run", "shot", "doctor"]

    static var text: String {
        // Commands whose help lives outside CLISpec.
        let extra = [
            "shot": "Install and open the app, then save a screenshot (and what is on screen) for checking a change.",
            "heal": "Watch a running simulator and turn a service back on when the app needs it.",
            "repairs": "List the services heal turned back on, and why.",
            "version": "Print the fast-ios version.",
        ]
        func line(_ name: String, everyday: Bool) -> String {
            let summary = CLISpec.find(name)?.summary ?? extra[name] ?? ""
            let padded = name.padding(toLength: 12, withPad: " ", startingAt: 0)
            // On a terminal, wrap at word boundaries under the summary column; piped output stays one line.
            let wrapped = Style.terminalWidth.map { CLISpec.wrap(summary, indent: "", width: max(30, $0 - 15)) }
                .map { $0.replacingOccurrences(of: "\n", with: "\n" + String(repeating: " ", count: 14)) } ?? summary
            return "  \(everyday ? Style.accent(padded) : Style.bold(padded))\(Style.code(wrapped))"
        }
        let names = CLISpec.commands.map(\.name)
        let advanced = names.filter { !everyday.contains($0) } + ["heal", "repairs", "version"].filter { !names.contains($0) }
        return """
        \(Style.accent("fast-ios")) \(Style.dim(FastIOSVersion.current)): light iOS simulators.

        \(Style.bold("Everyday"))
        \(everyday.map { line($0, everyday: true) }.joined(separator: "\n"))

        \(Style.bold("Advanced"))
        \(advanced.map { line($0, everyday: false) }.joined(separator: "\n"))

        \(Style.code("`fast-ios <command> --help` explains one command. `fast-ios` alone shows where you are."))
        \(Style.dim("Every command takes --json (for scripts and AI agents), --set <folder> (a separate set of"))
        \(Style.dim("simulators), --verbose and --no-color."))
        """
    }
}

/// `fast-ios on --dry-run` and `fast-ios off --dry-run`: say what would
/// change, change nothing.
func runSwitchDryRun(turningOn: Bool) async throws {
    let p = await AutoMode.plan(turningOn: turningOn, cliAutoConfig())
    if jsonMode {
        var v: [String: JSONValue] = [
            "schemaVersion": .int(Int64(JSONOutput.schemaVersion)), "dryRun": true, "turningOn": .bool(turningOn),
            "agentLabel": .string(p.agentLabel), "changesAgent": .bool(p.changesAgent),
            "wouldChange": .array(p.wouldChange.map { .string($0) }), "running": .array(p.running.map { .string($0) }),
        ]
        v["blockedBy"] = p.blockedBy.map { ["code": .string($0.kind.rawValue), "message": .string($0.message), "nextStep": .string($0.nextStep)] } ?? .null
        print(try JSONOutput.encode(JSONValue.object(v), pretty: true))
        return
    }
    print(Style.bold("Dry run:") + " " + Style.dim("nothing was changed."))
    if let b = p.blockedBy {
        print(b.message)
        print("Next: \(b.nextStep)")
        return
    }
    func list(_ names: [String]) -> String {
        names.count <= 3 ? names.joined(separator: ", ") : names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
    }
    if turningOn {
        print("fast-ios on would start the background helper, so new simulators start light.")
        print(p.wouldChange.isEmpty ? "No stopped simulator would change." : "\(p.wouldChange.count) stopped simulator\(p.wouldChange.count == 1 ? "" : "s") would become light: \(list(p.wouldChange)).")
        if !p.running.isEmpty { print("\(p.running.count) running simulator\(p.running.count == 1 ? "" : "s") would be left alone and become light after the next start: \(list(p.running)).") }
    } else {
        print(p.changesAgent ? "fast-ios off would stop and remove the background helper." : "No fast-ios helper is installed here, so none would be removed.")
        print(p.wouldChange.isEmpty ? "No stopped simulator would change." : "\(p.wouldChange.count) stopped simulator\(p.wouldChange.count == 1 ? "" : "s") would become full: \(list(p.wouldChange)).")
        if !p.running.isEmpty { print("\(p.running.count) running simulator\(p.running.count == 1 ? "" : "s") would get its services back now and be fully normal after the next start: \(list(p.running)).") }
    }
    print("Run the same command without --dry-run to do it.")
}
