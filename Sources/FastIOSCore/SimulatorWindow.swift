import Foundation

/// Shows a simulator's screen in a window, for a person who ran `fast-ios run`.
///
/// Apple's Simulator app (`com.apple.iphonesimulator`) opens a device from the
/// normal device set with `-CurrentDeviceUDID <udid>`. It has no option to
/// read another device set, so a simulator made with `--set` cannot get a
/// window: the result says so instead of opening the wrong one.
public enum SimulatorWindow {
    public enum Outcome: Sendable, Equatable {
        /// The window was asked for; the text says which app shows it.
        case opened(String)
        /// No window is possible; the text says why and what to use instead.
        case notPossible(String)
    }

    static let simulatorApp = "com.apple.iphonesimulator"

    /// Decides without side effects. `deviceSet` nil means the normal set.
    public static func plan(udid: String, name: String, deviceSet: String?, simulatorAppInstalled: Bool) -> Outcome {
        if deviceSet != nil {
            return .notPossible("No window opened: \(name) is in a separate set of simulators (--set), and the Simulator app shows only your normal simulators. See its screen with `fast-ios shot --udid \(udid) --app <app>`.")
        }
        guard simulatorAppInstalled else {
            return .notPossible("No window opened: the Simulator app was not found on this Mac. The app is running on \(name); see its screen with `fast-ios shot --udid \(udid) --app <app>`.")
        }
        return .opened("Opened the Simulator app on \(name).")
    }

    /// True when the selected Xcode has Simulator.app, where Xcode keeps it
    /// (`<developer dir>/Applications/Simulator.app`). Xcode 27.2 on the
    /// owner's Mac has none there.
    public static func simulatorAppInstalled() async -> Bool {
        guard let dir = try? await Shell.run("/usr/bin/xcode-select", ["-p"]) else { return false }
        let path = dir.text.trimmingCharacters(in: .whitespacesAndNewlines) + "/Applications/Simulator.app"
        return FileManager.default.fileExists(atPath: path)
    }

    /// Opens the window when `plan` allows it. Never boots another simulator:
    /// the device is already running when `run` calls this.
    public static func show(udid: String, name: String) async -> Outcome {
        let outcome = plan(udid: udid, name: name, deviceSet: Simctl.deviceSet, simulatorAppInstalled: await simulatorAppInstalled())
        guard case .opened = outcome else { return outcome }
        let r = try? await Shell.run("/usr/bin/open", ["-b", simulatorApp, "--args", "-CurrentDeviceUDID", udid], check: false)
        if r?.status == 0 { return outcome }
        return .notPossible("No window opened: macOS did not open the Simulator app. The app is running on \(name); open Simulator yourself, or use `fast-ios shot --udid \(udid) --app <app>`.")
    }
}
