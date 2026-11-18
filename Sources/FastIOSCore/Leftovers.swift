import Foundation

/// Everything fast-ios leaves on a Mac, for `fast-ios off` (which lists what
/// is left) and `fast-ios uninstall` (which removes it).
public struct Leftover: Sendable, Equatable {
    public enum Kind: String, Sendable { case helper, state, cache, log, app, commandLink, menuBarRunning }
    public let kind: Kind
    public let path: String
    /// Plain words: what it is.
    public let what: String
    /// `uninstall` deletes it; otherwise `howToRemove` says what to do.
    public let removable: Bool
    public let howToRemove: String?
}

public enum Leftovers {
    /// `~/Library/Caches/fast-ios` (the screen-tree runner). FASTIOS_CACHE_DIR
    /// moves it, for tests.
    public static var cacheFolder: URL {
        if let dir = ProcessInfo.processInfo.environment["FASTIOS_CACHE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("fast-ios", isDirectory: true)
    }

    /// Folders where the menu-bar app links the command (`FASTIOS_BIN_DIR` for tests).
    static var linkFolders: [URL] {
        if let dir = ProcessInfo.processInfo.environment["FASTIOS_BIN_DIR"] { return [URL(fileURLWithPath: dir)] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/opt/homebrew/bin", "/usr/local/bin"].map(URL.init(fileURLWithPath:)) + [home.appendingPathComponent(".local/bin")]
    }

    /// The app, where the installer puts it (`FASTIOS_APP_PATH` for tests).
    static var appPath: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["FASTIOS_APP_PATH"] ?? "/Applications/fast-ios.app")
    }

    /// What exists now. Read-only.
    public static func find(_ config: AutoModeConfig) async -> [Leftover] {
        let fm = FileManager.default
        var out: [Leftover] = []
        if fm.fileExists(atPath: config.plistURL.path) {
            out.append(Leftover(kind: .helper, path: config.plistURL.path, what: "the background helper \(config.label)", removable: true, howToRemove: nil))
        }
        let state = StateStore.url.deletingLastPathComponent()
        if fm.fileExists(atPath: state.path) {
            out.append(Leftover(kind: .state, path: state.path, what: "fast-ios's settings, leases and measurements", removable: true, howToRemove: nil))
        }
        if fm.fileExists(atPath: cacheFolder.path) {
            out.append(Leftover(kind: .cache, path: cacheFolder.path, what: "the screen-tree runner that `shot` built", removable: true, howToRemove: nil))
        }
        if fm.fileExists(atPath: config.logFile.path) {
            out.append(Leftover(kind: .log, path: config.logFile.path, what: "the helper's log", removable: true, howToRemove: nil))
        }
        for folder in linkFolders {
            let link = folder.appendingPathComponent("fast-ios")
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) else { continue }
            out.append(Leftover(kind: .commandLink, path: link.path, what: "the `fast-ios` command link (to \(dest))", removable: false,
                                howToRemove: "rm '\(link.path)'"))
        }
        if fm.fileExists(atPath: appPath.path) {
            out.append(Leftover(kind: .app, path: appPath.path, what: "the fast-ios app", removable: false,
                                howToRemove: "Quit it, then drag \(appPath.path) to the Trash. Remove it from System Settings > General > Login Items if it is listed."))
        }
        if await menuBarAppRunning() {
            out.append(Leftover(kind: .menuBarRunning, path: "", what: "the fast-ios menu-bar app, still running", removable: false,
                                howToRemove: "Quit it from its menu (the tiger icon) > Quit."))
        }
        return out
    }

    static func menuBarAppRunning() async -> Bool {
        ProcessTable.all().contains { $0.name == "FastIOSBar" }
    }

    /// Deletes every removable leftover except the helper (`off` removes it
    /// first). Returns what was removed and what could not be.
    public static func removeFiles(_ items: [Leftover]) -> (removed: [Leftover], failed: [(Leftover, String)]) {
        var removed: [Leftover] = [], failed: [(Leftover, String)] = []
        for item in items where item.removable && item.kind != .helper {
            do {
                try FileManager.default.removeItem(atPath: item.path)
                removed.append(item)
            } catch {
                failed.append((item, error.localizedDescription))
            }
        }
        return (removed, failed)
    }
}
