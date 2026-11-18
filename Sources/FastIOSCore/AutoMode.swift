import Foundation

// MARK: - Public API: the on/off switch

/// Runs `launchctl`. The real one is `SystemLaunchctl`; tests pass a fake.
public protocol LaunchctlRunner: Sendable {
    func run(_ arguments: [String]) async -> LaunchctlResult
}

public struct LaunchctlResult: Sendable, Equatable {
    public let status: Int32
    /// stdout and stderr together.
    public let output: String
    public init(status: Int32, output: String) { self.status = status; self.output = output }
}

/// `/bin/launchctl`, as the current user. Nothing here needs a password: the
/// helper is a user LaunchAgent in `gui/<uid>`.
public struct SystemLaunchctl: LaunchctlRunner {
    public init() {}
    public func run(_ arguments: [String]) async -> LaunchctlResult {
        guard let r = try? await Shell.run("/bin/launchctl", arguments, check: false) else {
            return LaunchctlResult(status: -1, output: "launchctl could not be started")
        }
        return LaunchctlResult(status: r.status, output: (r.text + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Who the switch is for. The CLI builds one from its environment; the Mac
/// app builds its own (its embedded CLI path, its own label in tests).
public struct AutoModeConfig: Sendable, Equatable {
    /// The program the LaunchAgent runs: a Homebrew `fast-ios`, or the CLI
    /// inside `fast-ios.app` (`…/Contents/MacOS/fast-ios` or wherever it is).
    public var executablePath: String
    /// The LaunchAgent label. Default `dev.fast-ios.auto`.
    public var label: String
    /// The device set to keep light; nil is the default set.
    public var deviceSet: String?
    public var launchAgentsFolder: URL
    public var logFile: URL
    public var userID: uid_t

    public static let defaultLabel = "dev.fast-ios.auto"

    public init(executablePath: String, label: String = AutoModeConfig.defaultLabel, deviceSet: String? = nil,
                launchAgentsFolder: URL? = nil, logFile: URL? = nil, userID: uid_t = getuid()) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.executablePath = executablePath
        self.label = label
        self.deviceSet = deviceSet.flatMap { $0.isEmpty ? nil : $0 }
        self.launchAgentsFolder = launchAgentsFolder ?? home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.logFile = logFile ?? home.appendingPathComponent("Library/Logs/fast-ios.log")
        self.userID = userID
    }

    /// The CLI's config: `FASTIOS_AGENT_LABEL` (tests) and `--set`.
    public static func fromEnvironment(executablePath: String) -> AutoModeConfig {
        let env = ProcessInfo.processInfo.environment
        let label = env["FASTIOS_AGENT_LABEL"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultLabel
        // FASTIOS_LOG_FILE keeps a test helper out of the real log.
        let log = env["FASTIOS_LOG_FILE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        return AutoModeConfig(executablePath: executablePath, label: label, deviceSet: Simctl.deviceSet, logFile: log)
    }

    public var plistURL: URL { launchAgentsFolder.appendingPathComponent("\(label).plist") }
    var domain: String { "gui/\(userID)" }
    var service: String { "\(domain)/\(label)" }
}

/// Another LaunchAgent that slims simulators (simslim's watch).
public struct OtherSlimmingAgent: Sendable, Codable, Hashable {
    public let label: String
    public let loaded: Bool
}

public struct AutoModeStatus: Sendable, Codable, Equatable {
    /// The helper is installed: fast-ios keeps simulators light.
    public let isOn: Bool
    public let agentInstalled: Bool
    /// launchd has the helper loaded (`launchctl print gui/<uid>/<label>`).
    public let agentLoaded: Bool
    public let agentLabel: String
    public let plistPath: String
    /// The device set in the installed helper (nil: default set, or not installed).
    public let deviceSet: String?
    /// The program the installed helper runs, from its plist.
    public let executablePath: String?
    /// The profile new and stopped simulators get: "general".
    public let profileName: String
    /// Services the general profile keeps on.
    public let keptServices: [String]
    public let conflictingAgents: [OtherSlimmingAgent]
    /// A conflicting agent would fight fast-ios: it watches the default set,
    /// and this config uses the default set.
    public let conflictBlocksTurningOn: Bool
    /// fast-ios helpers installed under other labels (a test label, an older
    /// install, the Mac app's own): a fast-ios helper may be running even
    /// when this label is off.
    public let otherFastIOSAgents: [OtherFastIOSAgent]
}

/// A LaunchAgent, under another label, whose program is fast-ios's helper.
public struct OtherFastIOSAgent: Sendable, Codable, Hashable {
    public let label: String
    public let loaded: Bool
    public let executablePath: String
    public let deviceSet: String?
}

/// What `turnOn` or `turnOff` would do, without doing it (`--dry-run`).
public struct AutoModePlan: Sendable, Equatable {
    public let turningOn: Bool
    /// Why it would stop without changing anything (another slimming tool,
    /// a missing program). nil: it would go ahead.
    public let blockedBy: AutoModeError?
    public let agentLabel: String
    public let plistPath: String
    /// Turning on: the helper would be written and loaded. Turning off: an
    /// installed helper would be unloaded and removed.
    public let changesAgent: Bool
    /// Stopped simulators that would change (light when turning on, full when turning off).
    public let wouldChange: [String]
    /// Running simulators: left alone when turning on (light after their next
    /// start); services turned back on when turning off.
    public let running: [String]
}

/// Every failure of the switch: what happened, in plain words, and what to do.
public struct AutoModeError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable, Codable {
        /// Another tool already slims simulators; nothing was changed.
        case conflictingAgent
        /// `executablePath` is not an executable file; nothing was changed.
        case executableMissing
        /// The helper's file could not be written or removed.
        case fileSystem
        /// launchctl refused to load or unload the helper.
        case launchctlFailed
        /// The helper's state changed, but simulators could not be listed or changed.
        case simulators
    }
    public let kind: Kind
    public let message: String
    public let nextStep: String
    public var errorDescription: String? { "\(message) \(nextStep)" }
}

public struct AutoModeOnResult: Sendable, Equatable {
    public let agentLabel: String
    /// Stopped simulators made light by this call.
    public let madeLight: [String]
    /// Simulators that were light before this call, running or not.
    public let alreadyLight: Int
    /// Running simulators that are full, left alone; light after their next start.
    public let runningLeftAlone: [String]
    /// The helper was already installed, loaded and unchanged: this call did nothing.
    public var alreadyOn: Bool = false
}

/// Whether a simulator is light, from its real state: a running simulator
/// asks its own launchd which services are disabled (a tool may have slimmed
/// it live, without fast-ios writing anything); a stopped one reads the
/// overrides it will boot with. `fast-ios`, `status` and `on` all use this.
public enum LightState {
    public typealias LiveReader = @Sendable (String) async -> Set<String>?

    /// `launchctl print-disabled system` inside the simulator; nil when it cannot be read.
    public static let liveDisabled: LiveReader = { udid in try? await Simctl.printDisabled(udid) }

    /// `countStillLight`: also count a running simulator that `off` made full
    /// on disk but that runs light until its next start.
    public static func isLight(_ device: SimDevice, live: LiveReader = liveDisabled, countStillLight: Bool = true) async -> Bool {
        let off: Set<String>
        if device.isBooted, let running = await live(device.udid) {
            off = running
        } else {
            off = DisabledStore.disabledLabels(device.udid)
        }
        if !off.intersection(ServiceCatalog.slimmable).isEmpty { return true }
        // `off` enabled its services, but they start only at its next start.
        guard countStillLight, device.isBooted, StateStore.load().fullAfterRestart?[device.udid] != nil else { return false }
        let age = await Measure.bootAge([device.udid])[device.udid]
        return Savings.Observation(device, diskDisabled: [], bootAge: age).startedBeforeMadeFull()
    }
}

public struct AutoModeOffResult: Sendable, Equatable {
    public let agentRemoved: Bool
    /// Stopped simulators made full.
    public let madeFull: [String]
    /// Running simulators: services turned back on now, fully normal after their next start.
    public let runningFullAfterRestart: [String]
}

/// `fast-ios on` and `fast-ios off`: keep every simulator light without
/// thinking about it.
public enum AutoMode {
    /// Reads the switch. Never throws: anything it cannot read shows as off or not loaded.
    public static func status(_ config: AutoModeConfig, launchctl: any LaunchctlRunner = SystemLaunchctl()) async -> AutoModeStatus {
        let installed = FileManager.default.fileExists(atPath: config.plistURL.path)
        let loaded = await launchctl.run(["print", config.service]).status == 0
        let plist = (try? Data(contentsOf: config.plistURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let args = plist?["ProgramArguments"] as? [String] ?? []
        let set = args.firstIndex(of: "--set").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let others = await otherSlimmingAgents(config, launchctl: launchctl)
        let profile = generalProfile()
        return AutoModeStatus(
            isOn: installed, agentInstalled: installed, agentLoaded: loaded, agentLabel: config.label,
            plistPath: config.plistURL.path, deviceSet: installed ? set : nil, executablePath: args.first,
            profileName: profile.name, keptServices: profile.keep.keys.sorted(),
            conflictingAgents: others, conflictBlocksTurningOn: !others.isEmpty && config.deviceSet == nil,
            otherFastIOSAgents: await otherFastIOSAgents(config, launchctl: launchctl))
    }

    /// Plists in the LaunchAgents folder, other than this config's, whose
    /// program runs `fast-ios … _agent`.
    public static func otherFastIOSAgents(_ config: AutoModeConfig, launchctl: any LaunchctlRunner = SystemLaunchctl()) async -> [OtherFastIOSAgent] {
        let files = (try? FileManager.default.contentsOfDirectory(at: config.launchAgentsFolder, includingPropertiesForKeys: nil)) ?? []
        var out: [OtherFastIOSAgent] = []
        for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "plist" && file != config.plistURL {
            guard let data = try? Data(contentsOf: file),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String,
                  let args = plist["ProgramArguments"] as? [String], let exe = args.first,
                  args.contains("_agent"), URL(fileURLWithPath: exe).lastPathComponent.hasPrefix("fast-ios") else { continue }
            let set = args.firstIndex(of: "--set").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            let loaded = await launchctl.run(["print", "\(config.domain)/\(label)"]).status == 0
            out.append(OtherFastIOSAgent(label: label, loaded: loaded, executablePath: exe, deviceSet: set))
        }
        return out
    }

    /// What `turnOn` / `turnOff` would do. Changes nothing.
    public static func plan(turningOn: Bool, _ config: AutoModeConfig, launchctl: any LaunchctlRunner = SystemLaunchctl(),
                            applyToSimulators: Bool = true) async -> AutoModePlan {
        let installed = FileManager.default.fileExists(atPath: config.plistURL.path)
        var blocked: AutoModeError?
        if turningOn {
            if !FileManager.default.isExecutableFile(atPath: config.executablePath) {
                blocked = AutoModeError(kind: .executableMissing, message: "The fast-ios program was not found at \(config.executablePath).",
                                        nextStep: "Reinstall fast-ios, or pass the path of the fast-ios program.")
            } else if config.deviceSet == nil, let other = await otherSlimmingAgents(config, launchctl: launchctl).first {
                blocked = AutoModeError(kind: .conflictingAgent,
                                        message: "fast-ios would not turn on, because simslim already makes your simulators light.",
                                        nextStep: "Stop simslim's helper first (launchctl bootout \(config.domain)/\(other.label)).")
            }
        }
        var change: [String] = [], running: [String] = []
        if applyToSimulators, blocked == nil {
            let devices = (try? await Simctl.$deviceSetOverride.withValue(config.deviceSet) { try await Simctl.listDevices() }) ?? []
            let recorded = StateStore.load().devices
            for d in devices where d.isAvailable {
                let off = DisabledStore.disabledLabels(d.udid)
                if turningOn {
                    if d.isBooted {
                        if !(await LightState.isLight(d)) { running.append(d.name) }
                        continue
                    }
                    let light = recorded[d.udid] != nil && !off.intersection(ServiceCatalog.slimmable).isEmpty
                    if d.state == "Shutdown", !light { change.append(d.name) }
                } else if !off.intersection(ServiceCatalog.managed).isEmpty {
                    if d.isBooted { running.append(d.name) } else { change.append(d.name) }
                }
            }
        }
        return AutoModePlan(turningOn: turningOn, blockedBy: blocked, agentLabel: config.label, plistPath: config.plistURL.path,
                            changesAgent: blocked == nil && (turningOn || installed), wouldChange: change, running: running)
    }

    /// Installs and loads the helper, then makes every stopped simulator in
    /// the set light (with `applyToSimulators`). Running simulators are left
    /// alone. Nothing is deleted. Refuses, changing nothing, when another
    /// slimming agent watches the same (default) set.
    public static func turnOn(_ config: AutoModeConfig, launchctl: any LaunchctlRunner = SystemLaunchctl(),
                              applyToSimulators: Bool = true) async throws(AutoModeError) -> AutoModeOnResult {
        guard FileManager.default.isExecutableFile(atPath: config.executablePath) else {
            throw AutoModeError(kind: .executableMissing,
                                message: "The fast-ios program was not found at \(config.executablePath).",
                                nextStep: "Reinstall fast-ios, or pass the path of the fast-ios program.")
        }
        if config.deviceSet == nil, let other = await otherSlimmingAgents(config, launchctl: launchctl).first {
            throw AutoModeError(kind: .conflictingAgent,
                                message: "fast-ios did not turn on, because simslim already makes your simulators light, and two tools doing this undo each other's work.",
                                nextStep: "Stop simslim's helper first (launchctl bootout \(config.domain)/\(other.label)), then turn fast-ios on again. Or keep simslim and leave fast-ios off.")
        }
        // Already on with the same program and set: do no work again.
        if await isInstalledAsConfigured(config), await launchctl.run(["print", config.service]).status == 0 {
            var counts = AutoModeOnResult(agentLabel: config.label, madeLight: [], alreadyLight: 0, runningLeftAlone: [])
            if applyToSimulators {
                counts = await Simctl.$deviceSetOverride.withValue(config.deviceSet) { await lightCounts(label: config.label) }
            }
            counts.alreadyOn = true
            return counts
        }
        try installAgent(config)
        _ = await launchctl.run(["bootout", config.service])
        let boot = await launchctl.run(["bootstrap", config.domain, config.plistURL.path])
        guard boot.status == 0 else {
            try? FileManager.default.removeItem(at: config.plistURL)
            throw AutoModeError(kind: .launchctlFailed,
                                message: "macOS did not start the fast-ios helper (\(boot.output.isEmpty ? "launchctl exit \(boot.status)" : boot.output)). Nothing was changed.",
                                nextStep: "Run `fast-ios doctor`, then try again.")
        }
        guard applyToSimulators else {
            return AutoModeOnResult(agentLabel: config.label, madeLight: [], alreadyLight: 0, runningLeftAlone: [])
        }
        do {
            return try await Simctl.$deviceSetOverride.withValue(config.deviceSet) {
                try await makeStoppedSimulatorsLight(label: config.label)
            }
        } catch {
            throw AutoModeError(kind: .simulators,
                                message: "fast-ios is on, but it could not make the stopped simulators light yet (\(error.localizedDescription)).",
                                nextStep: "They become light as they are created or restarted; run `fast-ios doctor` if this repeats.")
        }
    }

    /// Unloads and removes the helper, then makes every simulator in the set
    /// full (with `applyToSimulators`): stopped ones at once, running ones
    /// get their services turned back on now and are not restarted. Nothing
    /// is deleted.
    public static func turnOff(_ config: AutoModeConfig, launchctl: any LaunchctlRunner = SystemLaunchctl(),
                               applyToSimulators: Bool = true) async throws(AutoModeError) -> AutoModeOffResult {
        let existed = FileManager.default.fileExists(atPath: config.plistURL.path)
        _ = await launchctl.run(["bootout", config.service])
        if existed {
            do { try FileManager.default.removeItem(at: config.plistURL) } catch {
                throw AutoModeError(kind: .fileSystem,
                                    message: "The fast-ios helper is stopped, but its file \(config.plistURL.path) could not be removed (\(error.localizedDescription)).",
                                    nextStep: "Delete that file yourself so the helper does not start again at login.")
            }
        }
        PendingLight.clear()
        guard applyToSimulators else { return AutoModeOffResult(agentRemoved: existed, madeFull: [], runningFullAfterRestart: []) }
        do {
            return try await Simctl.$deviceSetOverride.withValue(config.deviceSet) {
                try await makeSimulatorsFull(agentRemoved: existed)
            }
        } catch {
            throw AutoModeError(kind: .simulators,
                                message: "The fast-ios helper is off, but simulators could not be made full (\(error.localizedDescription)).",
                                nextStep: "Run `fast-ios off` again; a simulator also goes back to full with `fast-ios off <simulator>`.")
        }
    }

    // MARK: Profile and other tools

    /// The profile for simulators whose app fast-ios does not know yet: the
    /// whole catalog off except what most apps under development use (push,
    /// the photo library, universal links, Spotlight for the document picker's
    /// Recents, speech), plus everything heal learned for any app. Measured on
    /// iPhone 18 Pro / iOS 27.0 with the same keep list: 85 processes, 638 MB.
    public static func generalProfile() -> SlimProfile {
        var keep: [String: [String]] = [:]
        let common: [(String, String)] = [
            ("com.apple.apsd", "push notifications"),
            ("com.apple.assetsd", "photo library and photo picker"),
            ("com.apple.assetsd.nebulad", "photo library and photo picker"),
            ("com.apple.swcd", "universal links"),
            ("com.apple.searchd", "Recents in the document picker"),
            ("com.apple.corespeechd", "speech recognition and dictation"),
        ]
        for (label, why) in common { keep[label, default: []].append("general profile: \(why)") }
        for (app, services) in HealStore.learned() {
            for label in services.keys { keep[label, default: []].append("heal learned it for \(app)") }
        }
        return Profiler.build(name: "general", appPath: nil, keep: keep)
    }

    /// LaunchAgents with "simslim" in the label, installed in the config's
    /// LaunchAgents folder or loaded. They watch the default and testing sets.
    public static func otherSlimmingAgents(_ config: AutoModeConfig, launchctl: any LaunchctlRunner = SystemLaunchctl()) async -> [OtherSlimmingAgent] {
        let plists = ((try? FileManager.default.contentsOfDirectory(atPath: config.launchAgentsFolder.path)) ?? [])
            .filter { $0.lowercased().contains("simslim") && $0.hasSuffix(".plist") }
            .map { String($0.dropLast(6)) }
        let loaded = await launchctl.run(["list"]).output
            .split(separator: "\n").compactMap { $0.split(separator: "\t").last.map(String.init) }
            .filter { $0.lowercased().contains("simslim") }
        return Set(plists + loaded).sorted().map { OtherSlimmingAgent(label: $0, loaded: loaded.contains($0)) }
    }

    // MARK: Steps

    static func installAgent(_ config: AutoModeConfig) throws(AutoModeError) {
        var args = [config.executablePath, "_agent"]
        if let set = config.deviceSet { args += ["--set", set] }
        var plist: [String: Any] = [
            "Label": config.label, "ProgramArguments": args, "RunAtLoad": true, "KeepAlive": true,
            "ProcessType": "Background", "StandardOutPath": config.logFile.path, "StandardErrorPath": config.logFile.path,
        ]
        // A custom state folder (tests, demos) must reach the helper too, or it
        // reads and writes the real one.
        if let dir = ProcessInfo.processInfo.environment["FASTIOS_STATE_DIR"], !dir.isEmpty {
            plist["EnvironmentVariables"] = ["FASTIOS_STATE_DIR": dir]
        }
        do {
            try FileManager.default.createDirectory(at: config.launchAgentsFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: config.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: config.plistURL, options: .atomic)
        } catch {
            throw AutoModeError(kind: .fileSystem,
                                message: "fast-ios could not write its helper file \(config.plistURL.path) (\(error.localizedDescription)). Nothing was changed.",
                                nextStep: "Check that you can write to \(config.launchAgentsFolder.path), then try again.")
        }
    }

    /// The installed plist runs this config's program on this config's set.
    static func isInstalledAsConfigured(_ config: AutoModeConfig) async -> Bool {
        guard let data = try? Data(contentsOf: config.plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return false }
        var expected = [config.executablePath, "_agent"]
        if let set = config.deviceSet { expected += ["--set", set] }
        return args == expected && plist["Label"] as? String == config.label
    }

    /// Counts for "already on": light ones (running or not) and running full ones.
    static func lightCounts(label: String) async -> AutoModeOnResult {
        var light = 0, runningFull: [String] = []
        for d in (try? await Simctl.listDevices()) ?? [] where d.isAvailable {
            if await LightState.isLight(d) { light += 1 } else if d.isBooted { runningFull.append(d.name) }
        }
        return AutoModeOnResult(agentLabel: label, madeLight: [], alreadyLight: light, runningLeftAlone: runningFull)
    }

    static func makeStoppedSimulatorsLight(label: String, live: LightState.LiveReader = LightState.liveDisabled) async throws -> AutoModeOnResult {
        let profile = generalProfile()
        var lightNow: [String] = [], running: [String] = []
        var already = 0
        let recorded = StateStore.load().devices
        var runningUDIDs: [String] = []
        defer { try? PendingLight.add(runningUDIDs) }
        for d in try await Simctl.listDevices() where d.isAvailable {
            if d.isBooted {
                // A running simulator another tool slimmed live is light already.
                // A full one becomes light as soon as it stops (PendingLight).
                if await LightState.isLight(d, live: live, countStillLight: false) {
                    already += 1
                } else if await LightState.isLight(d, live: live) {
                    // Light in memory only (`off` ran while it ran): its files
                    // say full, so it must still be made light when it stops.
                    already += 1; runningUDIDs.append(d.udid)
                } else {
                    running.append(d.name); runningUDIDs.append(d.udid)
                }
                continue
            }
            guard d.state == "Shutdown" else { continue }
            if recorded[d.udid] != nil, !DisabledStore.disabledLabels(d.udid).intersection(ServiceCatalog.slimmable).isEmpty {
                already += 1; continue
            }
            let change = try DisabledStore.apply(d.udid, disable: profile.disableSet)
            try StateStore.record(d.udid, profile: profile)
            if change.isEmpty { already += 1 } else { lightNow.append(d.name) }
        }
        return AutoModeOnResult(agentLabel: label, madeLight: lightNow, alreadyLight: already, runningLeftAlone: running)
    }

    static func makeSimulatorsFull(agentRemoved: Bool) async throws -> AutoModeOffResult {
        var full: [String] = [], running: [String] = []
        for d in try await Simctl.listDevices() where d.isAvailable {
            let managedOff = DisabledStore.disabledLabels(d.udid).intersection(ServiceCatalog.managed)
            guard !managedOff.isEmpty else { continue }
            if d.isBooted {
                // One `launchctl enable` per label (a shell inside the
                // simulator cannot start launchctl: "DYLD_ROOT_PATH not set"),
                // eight at a time; launchd_sim writes each enable to the store.
                let labels = managedOff.sorted()
                await withTaskGroup(of: Void.self) { group in
                    for (i, label) in labels.enumerated() {
                        if i >= 8 { await group.next() }
                        group.addTask { _ = try? await Simctl.simctl("spawn", d.udid, "launchctl", "enable", "system/\(label)", check: false) }
                    }
                }
                running.append(d.name)
            } else {
                try DisabledStore.apply(d.udid, disable: [])
                full.append(d.name)
            }
            let stillLight = d.isBooted
            try StateStore.update {
                $0.devices[d.udid] = nil
                // Enabled, but not started: light in memory until it restarts.
                if stillLight { $0.fullAfterRestart = ($0.fullAfterRestart ?? [:]).merging([d.udid: Date()]) { _, new in new } }
            }
        }
        return AutoModeOffResult(agentRemoved: agentRemoved, madeFull: full, runningFullAfterRestart: running)
    }

    // MARK: The helper itself

    /// What the helper runs (`fast-ios _agent`): make new simulators light
    /// before their first start with the general profile, and heal every
    /// running light simulator for whichever app it runs.
    public static func runAgent(log: @escaping @Sendable (String) -> Void) async {
        let watcher = Simctl.deviceSet.map { DeviceSetWatcher(setFolders: [URL(fileURLWithPath: $0)]) } ?? DeviceSetWatcher()
        log("fast-ios helper started; watching \(watcher.setFolders.map(\.path).joined(separator: ", "))")
        async let healing: Void = healRunning(log: log)
        async let pending: Void = lightenWhenStopped(log: log)
        async let trimming: Void = trimPool(log: log)
        await watcher.run { device in
            guard device.isShutdown else { return }
            let profile = generalProfile()
            do {
                let change = try DisabledStore.apply(device.udid, disable: profile.disableSet)
                try StateStore.record(device.udid, profile: profile)
                log("\(device.udid): new simulator made light before its first start (\(change.disabled.count) services off)")
            } catch {
                log("\(device.udid): could not make it light: \(error.localizedDescription)")
            }
        }
        await healing
        await pending
        await trimming
    }

    /// Simulators that were running at `fast-ios on` become light the moment
    /// they stop: checked every second while any are pending, so a quick
    /// quit-and-start still starts light.
    static func lightenWhenStopped(log: @escaping @Sendable (String) -> Void) async {
        while !Task.isCancelled {
            if !PendingLight.load().isEmpty, let devices = try? await Simctl.listDevices() {
                PendingLight.applyStopped(devices: devices, profile: generalProfile(), log: log)
            }
            try? await Task.sleep(for: .seconds(PendingLight.load().isEmpty ? 5 : 1))
        }
    }

    /// Once a minute: shut down free pool simulators fast-ios made that are
    /// not worth their memory (PoolTrim), so a warm one never sits on memory
    /// while the Mac is short of it.
    static func trimPool(log: @escaping @Sendable (String) -> Void) async {
        while !Task.isCancelled {
            await LeaseManager.trimIdle(log: { log($0) })
            try? await Task.sleep(for: .seconds(60))
        }
    }

    static func healRunning(log: @escaping @Sendable (String) -> Void) async {
        let healing = HealingSet()
        while !Task.isCancelled {
            let light = StateStore.load().devices
            for d in (try? await Simctl.listDevices()) ?? [] where d.isBooted && light[d.udid] != nil {
                guard await healing.insert(d.udid) else { continue }
                Task {
                    try? await Healer.runForUserApps(device: d, options: HealOptions()) { e in
                        if e.event == "repaired" || e.event == "repair-failed" || e.event == "cap-reached" {
                            log("\(d.udid): \(e.event) \(e.label ?? "") for \(e.bundleIdentifier): \(e.why ?? "")")
                        }
                    }
                    await healing.remove(d.udid)
                }
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

/// The simulators a heal loop is already following. An actor so concurrent
/// child tasks can share it.
public actor HealingSet {
    private var set = Set<String>()
    public init() {}
    public func contains(_ udid: String) -> Bool { set.contains(udid) }
    public func insert(_ udid: String) -> Bool { set.insert(udid).inserted }
    public func remove(_ udid: String) { set.remove(udid) }
}

/// The installed user apps of one simulator, executable name -> bundle id,
/// from `simctl listapps`. Refreshed when an unknown process shows up, at
/// most every 10 s, so a newly installed app is picked up.
actor UserApps {
    let udid: String
    private var byExecutable: [String: String] = [:]
    private var loadedAt = Date.distantPast

    init(udid: String) { self.udid = udid }

    func bundleID(forExecutable name: String) async -> String? {
        if let id = byExecutable[name] { return id }
        guard Date().timeIntervalSince(loadedAt) > 10 else { return nil }
        loadedAt = Date()
        guard let out = try? await Simctl.simctl("listapps", udid).stdout,
              let plist = try? PropertyListSerialization.propertyList(from: out, format: nil) as? [String: Any] else { return nil }
        var map: [String: String] = [:]
        for (id, value) in plist {
            guard let info = value as? [String: Any], info["ApplicationType"] as? String == "User",
                  let exe = info["CFBundleExecutable"] as? String else { continue }
            map[exe] = id
        }
        byExecutable = map
        return map[name]
    }
}
