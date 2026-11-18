import Foundation
import Synchronization
import Testing
@testable import FastIOSCore

/// A launchctl that remembers what it was asked and keeps a loaded set, so
/// the switch can be tested without touching launchd.
final class FakeLaunchctl: LaunchctlRunner {
    private let state = Mutex<(calls: [[String]], loaded: Set<String>, listed: [String], bootstrapStatus: Int32)>(
        (calls: [], loaded: [], listed: [], bootstrapStatus: 0))

    init(otherLoaded: [String] = [], bootstrapStatus: Int32 = 0) {
        state.withLock { $0.listed = otherLoaded; $0.bootstrapStatus = bootstrapStatus }
    }

    var calls: [[String]] { state.withLock { $0.calls } }

    func run(_ arguments: [String]) async -> LaunchctlResult {
        state.withLock { s in
            s.calls.append(arguments)
            switch arguments.first {
            case "print":
                return LaunchctlResult(status: s.loaded.contains(arguments[1]) ? 0 : 113, output: "")
            case "list":
                return LaunchctlResult(status: 0, output: (["PID\tStatus\tLabel"] + s.listed.map { "-\t0\t\($0)" }).joined(separator: "\n"))
            case "bootstrap":
                guard s.bootstrapStatus == 0 else { return LaunchctlResult(status: s.bootstrapStatus, output: "Bootstrap failed: 5: Input/output error") }
                // gui/<uid> + plist path -> service gui/<uid>/<label>
                let label = URL(fileURLWithPath: arguments[2]).deletingPathExtension().lastPathComponent
                s.loaded.insert("\(arguments[1])/\(label)")
                return LaunchctlResult(status: 0, output: "")
            case "bootout":
                return LaunchctlResult(status: s.loaded.remove(arguments[1]) != nil ? 0 : 3, output: "")
            default:
                return LaunchctlResult(status: 0, output: "")
            }
        }
    }
}

@Suite("On and off switch (fast-ios on / off)", .serialized)
struct AutoModeTests {
    /// A config with its own LaunchAgents folder and label; the executable is
    /// /usr/bin/true, which exists and is executable everywhere.
    static func config(deviceSet: String? = nil, executable: String = "/usr/bin/true") -> AutoModeConfig {
        let root = TestEnv.temp()
        return AutoModeConfig(executablePath: executable, label: "dev.fast-ios.test-\(UUID().uuidString.prefix(8))",
                              deviceSet: deviceSet, launchAgentsFolder: root.appendingPathComponent("LaunchAgents"),
                              logFile: root.appendingPathComponent("fast-ios.log"), userID: 501)
    }

    @Test("Turning on writes a user LaunchAgent that runs the given program, and loads it in gui/<uid>")
    func turnOnInstallsAndLoads() async throws {
        TestEnv.ready()
        let set = TestEnv.temp().path
        let c = Self.config(deviceSet: set)
        let launchctl = FakeLaunchctl()
        let before = await AutoMode.status(c, launchctl: launchctl)
        #expect(!before.isOn && !before.agentLoaded)

        let r = try await AutoMode.turnOn(c, launchctl: launchctl, applyToSimulators: false)
        #expect(r.agentLabel == c.label)

        let data = try Data(contentsOf: c.plistURL)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == c.label)
        #expect(plist["ProgramArguments"] as? [String] == ["/usr/bin/true", "_agent", "--set", set])
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(launchctl.calls.contains(["bootstrap", "gui/501", c.plistURL.path]))

        let after = await AutoMode.status(c, launchctl: launchctl)
        #expect(after.isOn && after.agentInstalled && after.agentLoaded)
        #expect(after.deviceSet == set && after.executablePath == "/usr/bin/true")
        #expect(after.profileName == "general" && after.keptServices.contains("com.apple.apsd"))
    }

    @Test("Turning off unloads and removes the LaunchAgent")
    func turnOffRemoves() async throws {
        TestEnv.ready()
        let c = Self.config(deviceSet: TestEnv.temp().path)
        let launchctl = FakeLaunchctl()
        _ = try await AutoMode.turnOn(c, launchctl: launchctl, applyToSimulators: false)
        let r = try await AutoMode.turnOff(c, launchctl: launchctl, applyToSimulators: false)
        #expect(r.agentRemoved)
        #expect(!FileManager.default.fileExists(atPath: c.plistURL.path))
        #expect(launchctl.calls.contains(["bootout", "gui/501/\(c.label)"]))
        let s = await AutoMode.status(c, launchctl: launchctl)
        #expect(!s.isOn && !s.agentLoaded)
        // Off twice is fine and says nothing was removed.
        #expect(try await AutoMode.turnOff(c, launchctl: launchctl, applyToSimulators: false).agentRemoved == false)
    }

    @Test("A simslim agent blocks turning on in the default set and changes nothing; a custom set is not blocked")
    func conflictingAgent() async throws {
        TestEnv.ready()
        let c = Self.config()
        let launchctl = FakeLaunchctl(otherLoaded: ["ai.example.simslim-watch"])
        let status = await AutoMode.status(c, launchctl: launchctl)
        #expect(status.conflictBlocksTurningOn)
        #expect(status.conflictingAgents == [OtherSlimmingAgent(label: "ai.example.simslim-watch", loaded: true)])

        await #expect(throws: AutoModeError.self) {
            _ = try await AutoMode.turnOn(c, launchctl: launchctl, applyToSimulators: false)
        }
        do {
            _ = try await AutoMode.turnOn(c, launchctl: launchctl, applyToSimulators: false)
        } catch {
            #expect(error.kind == .conflictingAgent)
            #expect(error.nextStep.contains("launchctl bootout gui/501/ai.example.simslim-watch"))
        }
        #expect(!FileManager.default.fileExists(atPath: c.plistURL.path))
        #expect(!launchctl.calls.contains { $0.first == "bootstrap" })

        // An installed (not loaded) simslim plist counts too.
        let c2 = Self.config()
        try FileManager.default.createDirectory(at: c2.launchAgentsFolder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: c2.launchAgentsFolder.appendingPathComponent("com.other.simslim.plist").path, contents: Data())
        #expect(await AutoMode.status(c2, launchctl: FakeLaunchctl()).conflictingAgents.map(\.label) == ["com.other.simslim"])

        // simslim watches the default set only, so a custom set is fine.
        let custom = Self.config(deviceSet: TestEnv.temp().path)
        _ = try await AutoMode.turnOn(custom, launchctl: launchctl, applyToSimulators: false)
        #expect(FileManager.default.fileExists(atPath: custom.plistURL.path))
    }

    @Test("A missing program or a launchctl refusal is a typed error with a next step, and leaves no LaunchAgent behind")
    func failuresLeaveNothing() async throws {
        TestEnv.ready()
        let missing = Self.config(deviceSet: TestEnv.temp().path, executable: "/nonexistent/fast-ios")
        do {
            _ = try await AutoMode.turnOn(missing, launchctl: FakeLaunchctl(), applyToSimulators: false)
            Issue.record("expected executableMissing")
        } catch {
            #expect(error.kind == .executableMissing && !error.nextStep.isEmpty)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.plistURL.path))

        let refused = Self.config(deviceSet: TestEnv.temp().path)
        do {
            _ = try await AutoMode.turnOn(refused, launchctl: FakeLaunchctl(bootstrapStatus: 5), applyToSimulators: false)
            Issue.record("expected launchctlFailed")
        } catch {
            #expect(error.kind == .launchctlFailed)
            #expect(error.message.contains("Input/output error"))
        }
        #expect(!FileManager.default.fileExists(atPath: refused.plistURL.path))
    }

    @Test("The device set is scoped to the call, not the process")
    func deviceSetIsTaskLocal() {
        #expect(Simctl.deviceSet == nil)
        let seen = Simctl.$deviceSetOverride.withValue("/tmp/fast-ios-scoped") { Simctl.deviceSet }
        #expect(seen == "/tmp/fast-ios-scoped")
        #expect(Simctl.deviceSet == nil)
    }

    @Test("Status notices a fast-ios helper installed and loaded under another label")
    func otherFastIOSHelper() async throws {
        TestEnv.ready()
        let c = Self.config(deviceSet: TestEnv.temp().path)
        let launchctl = FakeLaunchctl()
        // Another config (another label) in the same LaunchAgents folder turns on.
        let other = AutoModeConfig(executablePath: "/usr/local/bin/fast-ios", label: "dev.fast-ios.someone-else",
                                   deviceSet: "/tmp/other-set", launchAgentsFolder: c.launchAgentsFolder,
                                   logFile: c.logFile, userID: 501)
        try AutoMode.installAgent(other)
        _ = await launchctl.run(["bootstrap", "gui/501", other.plistURL.path])
        // A plist that is not fast-ios's does not count.
        try Data("<plist><dict><key>Label</key><string>com.example.x</string><key>ProgramArguments</key><array><string>/bin/x</string></array></dict></plist>".utf8)
            .write(to: c.launchAgentsFolder.appendingPathComponent("com.example.x.plist"))

        let s = await AutoMode.status(c, launchctl: launchctl)
        #expect(!s.isOn)
        #expect(s.otherFastIOSAgents == [OtherFastIOSAgent(label: "dev.fast-ios.someone-else", loaded: true,
                                                           executablePath: "/usr/local/bin/fast-ios", deviceSet: "/tmp/other-set")])
    }

    @Test("A dry run says what would change and changes nothing")
    func dryRun() async throws {
        TestEnv.ready()
        let blockedConfig = Self.config()
        let blocked = await AutoMode.plan(turningOn: true, blockedConfig, launchctl: FakeLaunchctl(otherLoaded: ["x.simslim.watch"]),
                                          applyToSimulators: false)
        #expect(blocked.blockedBy?.kind == .conflictingAgent && !blocked.changesAgent)

        let c = Self.config(deviceSet: TestEnv.temp().path)
        let launchctl = FakeLaunchctl()
        let on = await AutoMode.plan(turningOn: true, c, launchctl: launchctl, applyToSimulators: false)
        #expect(on.blockedBy == nil && on.changesAgent)
        let off = await AutoMode.plan(turningOn: false, c, launchctl: launchctl, applyToSimulators: false)
        #expect(!off.changesAgent)  // nothing installed, nothing to remove
        #expect(!FileManager.default.fileExists(atPath: c.plistURL.path))
        #expect(launchctl.calls.allSatisfy { $0.first == "list" || $0.first == "print" })
    }

    @Test("Turning on when already on does nothing again and says so")
    func alreadyOn() async throws {
        TestEnv.ready()
        let c = Self.config(deviceSet: TestEnv.temp().path)
        let launchctl = FakeLaunchctl()
        let first = try await AutoMode.turnOn(c, launchctl: launchctl, applyToSimulators: false)
        #expect(!first.alreadyOn)
        let written = try Data(contentsOf: c.plistURL)
        let second = try await AutoMode.turnOn(c, launchctl: launchctl, applyToSimulators: false)
        #expect(second.alreadyOn)
        #expect(launchctl.calls.filter { $0.first == "bootstrap" }.count == 1)
        #expect(try Data(contentsOf: c.plistURL) == written)

        // A different program path is a real change: reinstall, not "already on".
        var moved = c
        moved.executablePath = "/bin/ls"
        #expect(try await AutoMode.turnOn(moved, launchctl: launchctl, applyToSimulators: false).alreadyOn == false)
        #expect(launchctl.calls.filter { $0.first == "bootstrap" }.count == 2)
    }

    @Test("A running simulator is light when its launchd has the services disabled, even with no overrides written")
    func lightFromRealState() async {
        TestEnv.ready()
        let udid = TestEnv.fakeUDID()
        defer { TestEnv.cleanUp(udid) }
        let running = TestEnv.device(udid, state: "Booted")
        let slimmedLive: LightState.LiveReader = { _ in ["com.apple.tipsd", "com.apple.newsd"] }
        let stock: LightState.LiveReader = { _ in [] }
        let unreadable: LightState.LiveReader = { _ in nil }

        // Slimmed live by another tool: fast-ios wrote nothing, launchd says disabled.
        #expect(await LightState.isLight(running, live: slimmedLive))
        #expect(!(await LightState.isLight(running, live: stock)))
        // A stopped simulator is judged by the overrides it will boot with.
        let stopped = TestEnv.device(udid, state: "Shutdown")
        #expect(!(await LightState.isLight(stopped, live: slimmedLive)))
        try? DisabledStore.write(udid, ["com.apple.tipsd": true])
        #expect(await LightState.isLight(stopped, live: stock))
        // When the live state cannot be read, the overrides decide.
        #expect(await LightState.isLight(running, live: unreadable))
        // Only catalog services count: a non-catalog label disabled is not "light".
        #expect(!(await LightState.isLight(running, live: { _ in ["com.example.not-a-catalog-service"] })))
    }
}
