import FastIOSCore
import Foundation
import Observation

/// Where the switch's work happens: FastIOSCore's AutoMode, pointed at the
/// command line tool inside the app. A protocol so tests and previews can
/// stand in for it.
protocol KeepLightBackend: Sendable {
    func status() async -> AutoModeStatus
    func turnOn() async throws(AutoModeError) -> AutoModeOnResult
    func turnOff() async throws(AutoModeError) -> AutoModeOffResult
}

/// `fast-ios on` / `fast-ios off` through the library. The LaunchAgent runs
/// the CLI inside the app bundle, so it keeps working wherever the app lives
/// (move the app and the next switch rewrites the path).
struct CoreKeepLightBackend: KeepLightBackend {
    var config: AutoModeConfig {
        AutoModeConfig.fromEnvironment(executablePath: Self.executable)
    }

    /// The bundled CLI; in a `swift build` tree, the `fast-ios` beside this binary.
    static var executable: String {
        if let cli = AppBundle.embeddedCLI { return cli.path }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("fast-ios").path
    }

    func status() async -> AutoModeStatus { await AutoMode.status(config) }
    func turnOn() async throws(AutoModeError) -> AutoModeOnResult { try await AutoMode.turnOn(config) }
    func turnOff() async throws(AutoModeError) -> AutoModeOffResult { try await AutoMode.turnOff(config) }
}

/// "Keep simulators light", the app's one switch. Same as the CLI's
/// "Automatic: on/off".
@MainActor
@Observable
final class KeepLight {
    enum Phase: Equatable {
        case idle
        case working(turningOn: Bool)
        case failed(message: String, nextStep: String)
    }

    private(set) var status: AutoModeStatus?
    private(set) var phase: Phase = .idle
    /// Runs after every change, so the simulator list re-reads right away
    /// instead of at its next 5-second poll.
    var afterChange: (@MainActor () async -> Void)?
    private let backend: any KeepLightBackend

    init(backend: any KeepLightBackend = CoreKeepLightBackend()) {
        self.backend = backend
        refresh()
    }

    var isOn: Bool { status?.isOn ?? false }
    /// The first status read has come back.
    var isKnown: Bool { status != nil }
    /// Installed but launchd is not running it: the user turned fast-ios off
    /// under System Settings > General > Login Items & Extensions.
    var helperPaused: Bool { (status?.agentInstalled ?? false) && !(status?.agentLoaded ?? true) }
    /// simslim (or another tool) watches the same simulators; turning on
    /// would be refused.
    var conflict: OtherSlimmingAgent? {
        guard let status, status.conflictBlocksTurningOn, !status.isOn else { return nil }
        return status.conflictingAgents.first
    }

    func refresh() {
        Task { status = await backend.status() }
    }

    func set(_ on: Bool) {
        Task { await change(on) }
    }

    /// Turns the switch on or off and returns when it is done.
    func change(_ on: Bool) async {
        if case .working = phase { return }
        phase = .working(turningOn: on)
        do throws(AutoModeError) {
            if on { _ = try await backend.turnOn() } else { _ = try await backend.turnOff() }
            phase = .idle
        } catch {
            phase = .failed(message: error.message, nextStep: error.nextStep)
        }
        status = await backend.status()
        await afterChange?()
    }
}
