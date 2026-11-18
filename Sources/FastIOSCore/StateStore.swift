import Foundation

/// What fast-ios applied to each simulator, so the menu-bar app can show the
/// profile, and the profile `watch` applies to new simulators.
public struct FastIOSState: Sendable, Codable {
    public struct DeviceRecord: Sendable, Codable, Hashable {
        public var profileName: String
        public var appPath: String?
        public var disabledCount: Int
        public var updatedAt: Date
    }

    public var devices: [String: DeviceRecord] = [:]
    /// The last profile `slim` derived; `watch` uses it for new simulators.
    public var defaultProfile: SlimProfile?
    /// UDID -> when `fast-ios off` turned its services back on while it ran.
    /// Until its next start it is still light in memory (Savings).
    public var fullAfterRestart: [String: Date]?

    public init() {}
}

public enum StateStore {
    /// `~/Library/Application Support/fast-ios/state.json`. `FASTIOS_STATE_DIR`
    /// moves the folder (and with it leases, heal and pool files); the tests
    /// and the integration script use it so they never touch real state.
    public static var url: URL {
        if let dir = ProcessInfo.processInfo.environment["FASTIOS_STATE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("state.json")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("fast-ios", isDirectory: true).appendingPathComponent("state.json")
    }

    public static func load() -> FastIOSState {
        guard let data = try? Data(contentsOf: url) else { return FastIOSState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(FastIOSState.self, from: data)) ?? FastIOSState()
    }

    /// Records that `profile` was applied to a simulator.
    public static func record(_ udid: String, profile: SlimProfile) throws {
        try update {
            $0.devices[udid] = .init(profileName: profile.name, appPath: profile.appPath,
                                     disabledCount: profile.disable.count, updatedAt: Date())
        }
    }

    public static func update(_ change: (inout FastIOSState) -> Void) throws {
        var state = load()
        change(&state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
