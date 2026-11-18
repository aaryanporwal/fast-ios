import Foundation

/// A service `heal` turned back on for an app; every later profile for that
/// app keeps it.
public struct LearnedService: Codable, Sendable, Hashable {
    public let label: String
    public let machService: String
    /// The log line that showed the failed call.
    public let evidence: String
    public let learnedAt: Date
    public let udid: String
}

/// One `heal` event, as printed with --json and kept in repairs.jsonl.
public struct HealEvent: Codable, Sendable, Hashable {
    public var schemaVersion = JSONOutput.schemaVersion
    /// "healing" (started), "repaired", "repair-failed", "ignored", "cap-reached", "stopped".
    public let event: String
    public let time: String
    public let udid: String
    public let bundleIdentifier: String
    public var label: String? = nil
    public var machService: String? = nil
    /// The process whose log line showed the failure.
    public var process: String? = nil
    /// Why fast-ios acted or did not.
    public var why: String? = nil
    /// The log line, trimmed.
    public var evidence: String? = nil
    /// From the log line's time to the service answering launchctl print.
    public var repairMs: Int? = nil
    public var savedToProfile: Bool? = nil

    public init(event: String, udid: String, bundleIdentifier: String) {
        self.event = event
        self.time = ISO8601DateFormatter().string(from: Date())
        self.udid = udid
        self.bundleIdentifier = bundleIdentifier
    }
}

/// learned.json (bundle id -> label -> LearnedService) and repairs.jsonl,
/// beside state.json.
public enum HealStore {
    static var folder: URL { StateStore.url.deletingLastPathComponent() }
    public static var learnedURL: URL { folder.appendingPathComponent("learned.json") }
    public static var repairsURL: URL { folder.appendingPathComponent("repairs.jsonl") }

    public static func learned() -> [String: [String: LearnedService]] {
        guard let data = try? Data(contentsOf: learnedURL) else { return [:] }
        return (try? LeaseStore.decoder.decode([String: [String: LearnedService]].self, from: data)) ?? [:]
    }

    public static func learned(for bundleID: String) -> [String: LearnedService] { learned()[bundleID] ?? [:] }

    /// Adds a learned service under the lease lock, so parallel healers do
    /// not overwrite each other.
    public static func learn(_ service: LearnedService, bundleID: String) throws {
        _ = try LeaseStore.withLock { _ in
            var all = learned()
            all[bundleID, default: [:]][service.label] = service
            try LeaseStore.encoder.encode(all).write(to: learnedURL, options: .atomic)
        }
    }

    /// Forgets what heal learned for an app (all of it, or one label).
    public static func forget(bundleID: String, label: String? = nil) throws {
        _ = try LeaseStore.withLock { _ in
            var all = learned()
            if let label { all[bundleID]?[label] = nil } else { all[bundleID] = nil }
            try LeaseStore.encoder.encode(all).write(to: learnedURL, options: .atomic)
        }
    }

    /// Appends one event line. O_APPEND keeps concurrent short writes whole.
    public static func record(_ event: HealEvent) {
        guard let line = try? JSONOutput.encode(event, pretty: false) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(repairsURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    public static func repairs(udid: String? = nil, bundleID: String? = nil, limit: Int = 100) -> [HealEvent] {
        guard let text = try? String(contentsOf: repairsURL, encoding: .utf8) else { return [] }
        let events = text.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(HealEvent.self, from: Data($0.utf8))
        }.filter {
            ($0.event == "repaired" || $0.event == "repair-failed")
                && (udid == nil || $0.udid == udid) && (bundleID == nil || $0.bundleIdentifier == bundleID)
        }
        return Array(events.suffix(limit))
    }
}
