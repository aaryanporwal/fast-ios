import CoreServices
import Foundation

/// Slims new simulators before their first boot.
///
/// An FSEvents stream on ~/Library/Developer reports when a CoreSimulator
/// device-set folder (`CoreSimulator/Devices`, `XCTestDevices`) changes. Each
/// new device folder is read straight from its `device.plist` and, while it is
/// still shut down, gets the profile's overrides written into its launchd
/// store. Its first boot then starts none of those services. Existing
/// simulators are never touched.
public final class DeviceSetWatcher: Sendable {
    public let setFolders: [URL]

    public init(setFolders: [URL] = DeviceSetWatcher.defaultSetFolders) {
        self.setFolders = setFolders.map(\.standardizedFileURL)
    }

    public static var defaultSetFolders: [URL] {
        let dev = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer")
        return [dev.appendingPathComponent("CoreSimulator/Devices"), dev.appendingPathComponent("XCTestDevices")]
    }

    public struct NewDevice: Sendable {
        public let udid: String
        public let folder: URL
        public let isShutdown: Bool
    }

    /// Runs until the task is cancelled, calling `onNew` for each new device.
    public func run(onNew: @escaping @Sendable (NewDevice) async -> Void) async {
        var known: [URL: Set<String>] = [:]
        for folder in setFolders { known[folder] = Self.deviceFolders(in: folder) }

        let watchRoot = setFolders.map { $0.deletingLastPathComponent() }
            .reduce(nil as URL?) { acc, url in acc.map { Self.commonAncestor($0, url) } ?? url }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let changes = Self.folderEvents(root: watchRoot)

        for await paths in changes {
            let touched = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            // A set folder is rescanned when it, or a folder above it (when it
            // was just created, or FSEvents coalesced events), changed.
            let affected = setFolders.filter { folder in
                touched.contains { folder.path == $0 || folder.path.hasPrefix($0 + "/") }
            }
            for folder in affected {
                let now = Self.deviceFolders(in: folder)
                for udid in now.subtracting(known[folder] ?? []) {
                    let deviceFolder = folder.appendingPathComponent(udid)
                    if let state = await Self.waitForDevicePlist(deviceFolder) {
                        await onNew(NewDevice(udid: udid, folder: deviceFolder, isShutdown: state == 1))
                    }
                }
                known[folder] = now
            }
        }
    }

    static func deviceFolders(in folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.filter { UUID(uuidString: $0) != nil })
    }

    /// `simctl create` writes device.plist just after the folder. Returns its
    /// `state` (1 = Shutdown), or nil if it never appeared.
    static func waitForDevicePlist(_ folder: URL) async -> Int? {
        let plist = folder.appendingPathComponent("device.plist")
        for _ in 0..<200 {
            if let data = try? Data(contentsOf: plist),
               let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let state = dict["state"] as? Int {
                return state
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    static func commonAncestor(_ a: URL, _ b: URL) -> URL {
        let pa = a.pathComponents, pb = b.pathComponents
        let shared = zip(pa, pb).prefix { $0 == $1 }.map(\.0)
        return URL(fileURLWithPath: NSString.path(withComponents: shared))
    }

    /// Folder-level FSEvents under `root`, delivered as batches of paths.
    static func folderEvents(root: URL) -> AsyncStream<[String]> {
        AsyncStream { continuation in
            let box = Unmanaged.passRetained(ContinuationBox(continuation))
            var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info else { return }
                let box = Unmanaged<ContinuationBox>.fromOpaque(info).takeUnretainedValue()
                let array = unsafeBitCast(paths, to: NSArray.self)
                box.continuation.yield((0..<count).compactMap { array[$0] as? String })
            }
            let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
            guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [root.path] as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else {
                box.release()
                continuation.finish()
                return
            }
            let queue = DispatchQueue(label: "fast-ios.fsevents")
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            let handle = StreamHandle(stream)
            continuation.onTermination = { _ in
                queue.async {
                    FSEventStreamStop(handle.stream)
                    FSEventStreamInvalidate(handle.stream)
                    FSEventStreamRelease(handle.stream)
                    box.release()
                }
            }
        }
    }
}

private final class ContinuationBox: Sendable {
    let continuation: AsyncStream<[String]>.Continuation
    init(_ continuation: AsyncStream<[String]>.Continuation) { self.continuation = continuation }
}

/// The stream is only touched on its own serial queue after creation.
private final class StreamHandle: @unchecked Sendable {
    let stream: FSEventStreamRef
    init(_ stream: FSEventStreamRef) { self.stream = stream }
}
