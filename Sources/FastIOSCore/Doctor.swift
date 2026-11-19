import Foundation

/// `fast-ios doctor`: checks the Mac for what fast-ios needs, with a fix line
/// for each problem. Read-only.
public struct DoctorCheck: Encodable, Sendable {
    public let id: String
    /// "ok", "warn" or "fail".
    public let status: String
    public let summary: String
    /// What to do about it; null when the check passed.
    @EncodeNull public var fix: String?
}

public struct DoctorOutput: Encodable, Sendable {
    public var schemaVersion = JSONOutput.schemaVersion
    /// False when any check failed (warnings do not count).
    public let ok: Bool
    public let checks: [DoctorCheck]
    /// True when a new simulator could start now (the rule `lease` uses).
    public var canStartSimulator = true
}

public enum Doctor {
    /// `switchConfig`: also report whether `fast-ios on` is on (the CLI passes
    /// its own; the MCP tool leaves it out).
    public static func run(switchConfig: AutoModeConfig? = nil) async -> DoctorOutput {
        async let xcode = xcodeCheck()
        async let runtimes = runtimeCheck()
        async let simslim = simslimCheck()
        let memory = await memoryCheck()
        var checks = await [xcode, runtimes] + [memory, diskCheck(), stateCheck()] + simslim
        if let switchConfig { checks.append(await switchCheck(switchConfig)) }
        return DoctorOutput(ok: !checks.contains { $0.status == "fail" }, checks: checks,
                            canStartSimulator: memory.status == "ok")
    }

    static func xcodeCheck() async -> DoctorCheck {
        guard let path = try? await Shell.run("/usr/bin/xcode-select", ["-p"]),
              let version = try? await Shell.run("/usr/bin/xcrun", ["xcodebuild", "-version"]) else {
            return DoctorCheck(id: "xcode", status: "fail", summary: "Xcode is not installed or not selected.",
                               fix: "Install Xcode from the App Store, then run `sudo xcode-select -s /Applications/Xcode.app`.")
        }
        let dir = path.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = version.text.split(separator: "\n").joined(separator: " ")
        if dir.hasSuffix("CommandLineTools") {
            return DoctorCheck(id: "xcode", status: "fail", summary: "Only the Command Line Tools are selected (\(dir)); simctl needs Xcode.",
                               fix: "Run `sudo xcode-select -s /Applications/Xcode.app`.")
        }
        return DoctorCheck(id: "xcode", status: "ok", summary: "\(v) at \(dir)", fix: nil)
    }

    private struct Runtimes: Decodable {
        struct R: Decodable { let name: String; let version: String; let isAvailable: Bool; let platform: String? }
        let runtimes: [R]
    }

    static func runtimeCheck() async -> DoctorCheck {
        guard let out = try? await Shell.run("/usr/bin/xcrun", ["simctl", "list", "runtimes", "-j"]),
              let list = try? JSONDecoder().decode(Runtimes.self, from: out.stdout) else {
            return DoctorCheck(id: "runtimes", status: "fail", summary: "`xcrun simctl list runtimes` failed.",
                               fix: "Open Xcode once to finish installing its components, then rerun `fast-ios doctor`.")
        }
        let ios = list.runtimes.filter { $0.isAvailable && ($0.platform ?? "iOS") == "iOS" }
        guard !ios.isEmpty else {
            return DoctorCheck(id: "runtimes", status: "fail", summary: "No iOS simulator runtime is installed.",
                               fix: "Run `xcodebuild -downloadPlatform iOS`.")
        }
        let names = ios.map(\.name).joined(separator: ", ")
        let persistent = ios.contains { $0.version.compare("18.5", options: .numeric) != .orderedAscending }
        if !persistent {
            return DoctorCheck(id: "runtimes", status: "warn", summary: "iOS runtimes: \(names). None is 18.5 or newer, so light simulators turn full again after a restart.",
                               fix: "Run `xcodebuild -downloadPlatform iOS` to get a current runtime.")
        }
        return DoctorCheck(id: "runtimes", status: "ok", summary: "iOS runtimes: \(names)", fix: nil)
    }

    static func simslimCheck() async -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        let agents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let plists = ((try? FileManager.default.contentsOfDirectory(atPath: agents.path)) ?? [])
            .filter { $0.lowercased().contains("simslim") && $0.hasSuffix(".plist") }
        let loaded = (try? await Shell.run("/bin/launchctl", ["list"]))?.text
            .split(separator: "\n").compactMap { $0.split(separator: "\t").last.map(String.init) }
            .filter { $0.lowercased().contains("simslim") } ?? []
        let labels = Set(loaded + plists.map { String($0.dropLast(6)) }).sorted()
        if labels.isEmpty {
            checks.append(DoctorCheck(id: "simslim-watch", status: "ok", summary: "No simslim watch agent.", fix: nil))
        } else {
            checks.append(DoctorCheck(
                id: "simslim-watch", status: "warn",
                summary: "simslim watch agent present (\(labels.joined(separator: ", "))\(loaded.isEmpty ? ", not loaded" : ", loaded")). It makes every simulator in the default device set light with its own list, so `fast-ios off` does not stay full there.",
                fix: "Give fast-ios its own device set with `--set <path>`, or stop the agent yourself: `launchctl bootout gui/$(id -u)/\(labels[0])`."))
        }
        return checks
    }

    /// Judged with the same rule as `lease` and `run` (MemoryAdvice.judge),
    /// so doctor never says yes while they refuse.
    static func memoryCheck() async -> DoctorCheck {
        let m = MemoryStatus.read()
        let summary = "Memory pressure \(m.pressure), \(m.availableMB) MB of \(m.totalMB) MB available."
        let (can, _) = MemoryAdvice.judge(m, policy: AdmissionPolicy())
        if can {
            return DoctorCheck(id: "memory", status: "ok", summary: summary + " A new simulator can start now.", fix: nil)
        }
        let advice = await MemoryAdvice.current(memory: m)
        let detail = ([summary, "A new simulator cannot start right now: " + lowerFirst(advice.why)] + advice.usage).joined(separator: " ")
        // Critical pressure is a failure; anything else only blocks new simulators.
        return DoctorCheck(id: "memory", status: m.pressure == "critical" ? "fail" : "warn", summary: detail,
                           fix: advice.nextStep + " `fast-ios run` and `fast-ios lease` stop at once until then; `--wait-for-memory 5m` makes them wait.")
    }

    static func switchCheck(_ config: AutoModeConfig) async -> DoctorCheck {
        let s = await AutoMode.status(config)
        if s.isOn && s.agentLoaded {
            return DoctorCheck(id: "automatic", status: "ok", summary: "fast-ios is on: its background helper is running and keeps simulators light.", fix: nil)
        }
        if s.isOn {
            return DoctorCheck(id: "automatic", status: "warn", summary: "fast-ios is on, but its background helper is not running.",
                               fix: "Run `fast-ios on` again.")
        }
        return DoctorCheck(id: "automatic", status: "ok", summary: "fast-ios is off: simulators stay as they are. Turn it on with `fast-ios on`.", fix: nil)
    }

    static func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

    static func diskCheck() -> DoctorCheck {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let gb = Int(free / 1_000_000_000)
        if gb < 10 {
            return DoctorCheck(id: "disk", status: "warn", summary: "\(gb) GB free on the home volume; each new simulator takes 1 to 5 GB.",
                               fix: "Delete simulators you created and no longer need (`xcrun simctl delete <udid>`), or run `xcrun simctl delete unavailable`.")
        }
        return DoctorCheck(id: "disk", status: "ok", summary: "\(gb) GB free on the home volume.", fix: nil)
    }

    static func stateCheck() -> DoctorCheck {
        let url = StateStore.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DoctorCheck(id: "state", status: "ok", summary: "No fast-ios state yet (\(url.path)).", fix: nil)
        }
        guard let data = try? Data(contentsOf: url), (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return DoctorCheck(id: "state", status: "warn", summary: "\(url.path) is not valid JSON; fast-ios ignores it.",
                               fix: "Move it aside: `mv '\(url.path)' '\(url.path).bad'`. fast-ios writes a new one when it next changes a simulator.")
        }
        return DoctorCheck(id: "state", status: "ok", summary: "State file \(url.path) is readable.", fix: nil)
    }
}
