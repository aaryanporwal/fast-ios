import AppKit
import FastIOSCore
import ServiceManagement

/// Facts about the running app bundle.
enum AppBundle {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The `fast-ios` command line tool shipped inside the app, if this is a
    /// bundled build (a `swift run` build has none).
    static var embeddedCLI: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/fast-ios")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The tiger template for the menu bar; the hare symbol in builds that
    /// are not bundled.
    static func menuBarImage(filled: Bool) -> NSImage? {
        if let image = Bundle.main.image(forResource: "MenuBarIcon") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        let image = NSImage(systemSymbolName: filled ? "hare.fill" : "hare", accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}

/// "Open at login", through SMAppService (macOS shows its "Background item
/// added" notice the first time).
enum LoginItem {
    enum State: Equatable { case on, off, needsApproval, unavailable }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notRegistered: .off
        case .notFound: .unavailable
        @unknown default: .off
        }
    }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Puts `fast-ios` on the PATH with a symlink, in the first folder the user
/// can write to without a password.
enum CLIInstaller {
    struct Result: Equatable {
        let link: URL
        /// False when the folder is not on the user's PATH; the copy says how
        /// to add it.
        let onPath: Bool
    }

    static var candidates: [URL] {
        // Tests point this at a scratch folder so they never touch real PATH folders.
        if let dir = ProcessInfo.processInfo.environment["FASTIOS_BIN_DIR"] { return [URL(fileURLWithPath: dir)] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/opt/homebrew/bin", "/usr/local/bin"].map(URL.init(fileURLWithPath:)) + [home.appendingPathComponent(".local/bin")]
    }

    /// Where the tool is installed now, if anywhere (a link to this app's copy,
    /// or any `fast-ios` already on one of the folders).
    static var installed: URL? {
        candidates.map { $0.appendingPathComponent("fast-ios") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func install() throws -> Result {
        guard let source = AppBundle.embeddedCLI else {
            throw AppError("This build has no command line tool inside it. Install fast-ios with Homebrew instead.")
        }
        let fm = FileManager.default
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in candidates {
            let isHome = dir.path.hasPrefix(fm.homeDirectoryForCurrentUser.path)
            if isHome { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            guard fm.isWritableFile(atPath: dir.path) else { continue }
            let link = dir.appendingPathComponent("fast-ios")
            let target = try? fm.destinationOfSymbolicLink(atPath: link.path)
            let ours = target?.contains(".app/Contents/MacOS/fast-ios") ?? false
            if (fm.fileExists(atPath: link.path) || target != nil) && !ours {
                // Someone else's install, such as Homebrew's link into its
                // Cellar: leave it, it already works.
                return Result(link: link, onPath: !isHome || path.contains(dir.path))
            }
            if target != nil { try fm.removeItem(at: link) }
            try fm.createSymbolicLink(at: link, withDestinationURL: source)
            // An app started from Finder sees a short PATH; Homebrew's and
            // /usr/local's folders are on every login shell's PATH.
            let onPath = !isHome || path.contains(dir.path)
            return Result(link: link, onPath: onPath)
        }
        throw AppError("No folder on your PATH can be written without a password.")
    }
}

/// An error whose message is written for the person reading it.
struct AppError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
