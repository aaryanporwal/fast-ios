import Foundation

/// The simulator's launchd disable overrides.
///
/// launchd_sim is a host process, so the overrides live beside the device's
/// launchd.log in a per-UDID host folder, not in the device's data folder:
/// `/private/var/tmp/com.apple.CoreSimulator.SimDevice.<UDID>/disabled.plist`.
/// launchd_sim reads it when it starts and rewrites it on every
/// `launchctl disable`/`enable`. The shape is a flat dict of label -> bool.
/// (Path and shape from simslim's disabled_store.go.)
///
/// Write only while the device is shut down: a running launchd_sim keeps its
/// own copy in memory and may write it back.
public enum DisabledStore {
    public static let root = URL(fileURLWithPath: "/private/var/tmp")

    public static func folder(_ udid: String) -> URL {
        root.appendingPathComponent("com.apple.CoreSimulator.SimDevice.\(udid)", isDirectory: true)
    }

    public static func path(_ udid: String) -> URL {
        folder(udid).appendingPathComponent("disabled.plist")
    }

    /// Every entry verbatim, including the explicit `false` entries the runtime
    /// writes for itself. A device that never booted has no file: nothing is
    /// disabled, so that is an empty dict, not an error.
    public static func read(_ udid: String) throws -> [String: Bool] {
        let url = path(udid)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = plist as? [String: Any] else { return [:] }
        return dict.compactMapValues { $0 as? Bool }
    }

    public static func disabledLabels(_ udid: String) -> Set<String> {
        let entries = (try? read(udid)) ?? [:]
        return Set(entries.filter(\.value).keys)
    }

    /// Writes the store atomically (temp file in the same folder, then
    /// rename(2)) so launchd_sim can never read a half-written file.
    public static func write(_ udid: String, _ entries: [String: Bool]) throws {
        let dir = folder(udid)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
        let temp = dir.appendingPathComponent("disabled.plist.\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data,
                                             attributes: [.posixPermissions: 0o644]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        if rename(temp.path, path(udid).path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    public struct Change: Sendable {
        public let disabled: [String]
        public let reenabled: [String]
        public var isEmpty: Bool { disabled.isEmpty && reenabled.isEmpty }
    }

    /// Makes the managed labels match `disable`: each label in `disable` gets
    /// `true`; each other managed label that is `true` loses its entry, which
    /// returns it to the job's own default. Entries outside `managed` are
    /// never touched. Writes nothing when nothing changes.
    @discardableResult
    public static func apply(_ udid: String, disable: Set<String>, managed: Set<String> = ServiceCatalog.managed) throws -> Change {
        let safe = disable.intersection(managed).filter { !NeverDisable.isProtected($0) }
        var entries = try read(udid)
        var disabled: [String] = [], reenabled: [String] = []
        for label in safe where entries[label] != true {
            entries[label] = true
            disabled.append(label)
        }
        for (label, value) in entries where value && managed.contains(label) && !safe.contains(label) {
            entries[label] = nil
            reenabled.append(label)
        }
        let change = Change(disabled: disabled.sorted(), reenabled: reenabled.sorted())
        if !change.isEmpty { try write(udid, entries) }
        return change
    }
}
