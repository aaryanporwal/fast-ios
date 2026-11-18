import Foundation

extension Doctor {
    /// Xcode's licence and first-launch components. `xcrun simctl` fails
    /// until both are done, with messages a new user rarely connects to it.
    /// Read-only: `-license check` and `-checkFirstLaunchStatus` change nothing.
    public static func firstLaunchCheck() async -> DoctorCheck {
        let license = try? await Shell.run("/usr/bin/xcrun", ["xcodebuild", "-license", "check"], check: false)
        if let license, license.status != 0 {
            return DoctorCheck(id: "xcode-license", status: "fail",
                               summary: "The Xcode licence has not been accepted on this Mac.",
                               fix: "Run `sudo xcodebuild -license accept` in Terminal (it asks for your password), or open Xcode once and agree.")
        }
        let first = try? await Shell.run("/usr/bin/xcrun", ["xcodebuild", "-checkFirstLaunchStatus"], check: false)
        if let first, first.status != 0 {
            return DoctorCheck(id: "xcode-license", status: "fail",
                               summary: "Xcode has not finished installing its components.",
                               fix: "Open Xcode once and let it install, or run `xcodebuild -runFirstLaunch` in Terminal.")
        }
        return DoctorCheck(id: "xcode-license", status: "ok", summary: "Xcode licence accepted and components installed.", fix: nil)
    }
}
