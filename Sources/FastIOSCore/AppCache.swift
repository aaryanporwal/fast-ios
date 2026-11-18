import Foundation

extension EncodeNull: Decodable where T: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = c.decodeNil() ? nil : try c.decode(T.self)
    }
}
extension EncodeNull: Equatable where T: Equatable {
    public static func == (a: Self, b: Self) -> Bool { a.wrappedValue == b.wrappedValue }
}

/// One stored app: `<cache>/apps/<fingerprint>/manifest.json` next to the .app.
public struct CachedApp: Sendable, Codable, Equatable {
    public var schema = 1
    public let fingerprint: String
    public let kind: AppFingerprint.Kind
    public let projectID: String
    /// The project folder's name when it was stored (for people only).
    public let projectName: String
    public let configuration: String
    @EncodeNull public var variant: String?
    public let bundleIdentifier: String
    /// File name of the .app inside the entry folder.
    public let appName: String
    public let architectures: [String]
    public let xcodeVersion: String
    /// When the .app was built (its executable's modification date).
    public let builtAt: Date
    public let storedAt: Date
    public var lastUsedAt: Date
    public let sizeBytes: Int64
    /// How long the build took, when fast-ios ran it (`--build`).
    @EncodeNull public var buildSeconds: Double?
    public let inputs: [String: String]
}

/// Why `run` used, built or skipped the app cache. In `run --json` as `appCache`.
public struct AppCacheSummary: Sendable, Codable, Equatable {
    /// hit: reused a stored app. built: this call built and stored it.
    /// waited: another agent built it while this one waited.
    /// miss: no stored app matches and nothing was built (a local build was used).
    public let status: String
    public let fingerprint: String
    public let kind: AppFingerprint.Kind
    /// ISO 8601.
    @EncodeNull public var builtAt: String?
    /// Compile time skipped on a hit, when the stored app's build was timed.
    @EncodeNull public var savedSeconds: Double?
    public let message: String
}

public struct AppCacheError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum AppCache {
    /// `~/Library/Caches/fast-ios/apps`, or `$FASTIOS_CACHE_DIR/apps`.
    public static var folder: URL {
        if let dir = ProcessInfo.processInfo.environment["FASTIOS_CACHE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true).appendingPathComponent("apps")
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fast-ios/apps", isDirectory: true)
    }

    /// Size cap in bytes: `FASTIOS_APP_CACHE_GB` (default 10).
    public static var maxBytes: Int64 {
        let gb = ProcessInfo.processInfo.environment["FASTIOS_APP_CACHE_GB"].flatMap(Double.init) ?? 10
        return Int64(gb * 1_073_741_824)
    }

    static func entry(_ fingerprint: String) -> URL { folder.appendingPathComponent(fingerprint, isDirectory: true) }

    // MARK: Reading

    /// Every stored app, most recently used first.
    public static func list() -> [CachedApp] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.compactMap { load($0) }.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    static func load(_ fingerprint: String) -> CachedApp? {
        let url = entry(fingerprint).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url), let m = try? decoder.decode(CachedApp.self, from: data) else { return nil }
        // An entry whose app is gone (cleared by hand) is no entry.
        guard FileManager.default.fileExists(atPath: entry(fingerprint).appendingPathComponent(m.appName).path) else { return nil }
        return m
    }

    public static func appURL(_ m: CachedApp) -> URL { entry(m.fingerprint).appendingPathComponent(m.appName) }

    /// The stored app for this fingerprint, checked again before it is
    /// reused: same fingerprint, same configuration, built for this Mac's
    /// architecture. Marks it used.
    public static func lookup(_ fp: AppFingerprint) -> CachedApp? {
        guard var m = load(fp.hash), m.fingerprint == fp.hash, m.configuration == fp.configuration,
              m.kind == fp.kind, m.architectures.contains(Fingerprinter.hostArch()) else { return nil }
        m.lastUsedAt = Date()
        try? save(m)
        return m
    }

    /// True when anything is stored for this project: `run` computes a
    /// fingerprint only then (or with --build), so the cache costs nothing
    /// until it is used.
    public static func hasEntries(projectID: String) -> Bool {
        list().contains { $0.projectID == projectID }
    }

    // MARK: Writing

    /// Checks that `app` may be stored under `fp` and returns its facts.
    /// Refuses a device build, an app without a bundle ID, an app not built
    /// for this Mac, and a configuration that does not match the path.
    static func validate(_ app: URL, fp: AppFingerprint) async throws -> (bundle: String, archs: [String], builtAt: Date) {
        let info = app.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AppCacheError("\(app.path) has no readable Info.plist, so it is not a built app. Pass the .app your build produced.")
        }
        guard let bundle = plist["CFBundleIdentifier"] as? String, !bundle.isEmpty else {
            throw AppCacheError("\(app.lastPathComponent) has no CFBundleIdentifier. fast-ios stores only apps it can launch.")
        }
        let platforms = plist["CFBundleSupportedPlatforms"] as? [String] ?? []
        guard platforms.contains("iPhoneSimulator") else {
            throw AppCacheError("\(app.lastPathComponent) is built for \(platforms.first ?? "an unknown platform"), not the iOS Simulator. Build with an iOS Simulator destination and store that .app.")
        }
        if let inferred = configuration(fromPath: app.path), inferred != fp.configuration {
            throw AppCacheError("\(app.lastPathComponent) is a \(inferred) build (its folder says so), but the configuration is \(fp.configuration). Pass --configuration \(inferred), or store the \(fp.configuration) build.")
        }
        // An app with its JavaScript inside cannot be keyed by native inputs alone.
        if fp.kind == .expo, FileManager.default.fileExists(atPath: app.appendingPathComponent("main.jsbundle").path) {
            throw AppCacheError("\(app.lastPathComponent) has its JavaScript built in (main.jsbundle), so a JavaScript change would make it wrong. fast-ios stores Debug simulator builds that load JavaScript from Metro; store a build without FORCE_BUNDLING, or use --configuration Release to key it by every file.")
        }
        let exe = app.appendingPathComponent(plist["CFBundleExecutable"] as? String ?? app.deletingPathExtension().lastPathComponent)
        let archs = try await architectures(exe)
        guard archs.contains(Fingerprinter.hostArch()) else {
            throw AppCacheError("\(app.lastPathComponent) is built for \(archs.joined(separator: ", ")), not this Mac (\(Fingerprinter.hostArch())). Build it again on this Mac.")
        }
        let built = (try? exe.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return (bundle, archs, built)
    }

    /// "Debug" from ".../Debug-iphonesimulator/App.app", else nil.
    public static func configuration(fromPath path: String) -> String? {
        for part in path.split(separator: "/").reversed() where part.hasSuffix("-iphonesimulator") || part.hasSuffix("-iphoneos") {
            return String(part.split(separator: "-").dropLast().joined(separator: "-"))
        }
        return nil
    }

    static func architectures(_ executable: URL) async throws -> [String] {
        let r = try await Shell.run("/usr/bin/lipo", ["-archs", executable.path], check: false)
        let archs = r.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard r.status == 0, !archs.isEmpty else {
            throw AppCacheError("Cannot read the architectures of \(executable.path) (lipo: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))). Is the app complete?")
        }
        return archs
    }

    /// Stores a copy of `app` under `fp`. The copy is an APFS clone, so it
    /// takes no extra disk space until one side changes. If another process
    /// stored the same fingerprint first, keeps that one. Then evicts the
    /// least recently used apps beyond the size cap.
    @discardableResult
    public static func add(_ app: URL, fingerprint fp: AppFingerprint, projectName: String,
                           variant: String? = nil, buildSeconds: Double? = nil) async throws -> CachedApp {
        let app = app.standardizedFileURL
        let facts = try await validate(app, fp: fp)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let incoming = folder.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: incoming) }
        let copy = incoming.appendingPathComponent(app.lastPathComponent)
        try fm.copyItem(at: app, to: copy)
        let now = Date()
        let m = CachedApp(fingerprint: fp.hash, kind: fp.kind, projectID: fp.projectID, projectName: projectName,
                          configuration: fp.configuration, variant: variant, bundleIdentifier: facts.bundle,
                          appName: app.lastPathComponent, architectures: facts.archs,
                          xcodeVersion: fp.inputs["xcode"] ?? "unknown", builtAt: facts.builtAt, storedAt: now,
                          lastUsedAt: now, sizeBytes: size(of: copy), buildSeconds: buildSeconds, inputs: fp.inputs)
        try encoder.encode(m).write(to: incoming.appendingPathComponent("manifest.json"), options: .atomic)
        let target = entry(fp.hash)
        if fm.fileExists(atPath: target.path) {
            if let existing = load(fp.hash) { return existing }
            try fm.removeItem(at: target)  // a broken entry: replace it
        }
        do {
            try fm.moveItem(at: incoming, to: target)
        } catch {
            if let existing = load(fp.hash) { return existing }
            throw error
        }
        evict(keeping: fp.hash)
        return m
    }

    static func save(_ m: CachedApp) throws {
        try encoder.encode(m).write(to: entry(m.fingerprint).appendingPathComponent("manifest.json"), options: .atomic)
    }

    /// Removes least recently used entries until the total is within
    /// `maxBytes`. Never removes `keeping`. Returns what was removed.
    @discardableResult
    public static func evict(keeping: String? = nil, maxBytes cap: Int64? = nil) -> [CachedApp] {
        let cap = cap ?? maxBytes
        var all = list()
        var total = all.reduce(0) { $0 + $1.sizeBytes }
        var removed: [CachedApp] = []
        while total > cap, let victim = all.last(where: { $0.fingerprint != keeping }) {
            try? FileManager.default.removeItem(at: entry(victim.fingerprint))
            total -= victim.sizeBytes
            all.removeAll { $0.fingerprint == victim.fingerprint }
            removed.append(victim)
        }
        return removed
    }

    /// Removes one entry (by full or short fingerprint), or all with nil.
    public static func clear(_ fingerprint: String? = nil) throws -> [CachedApp] {
        let targets = list().filter { fingerprint == nil || $0.fingerprint.hasPrefix(fingerprint!) }
        if let fingerprint, targets.isEmpty {
            throw AppCacheError("No stored app has the fingerprint \(fingerprint). See them with `fast-ios apps`.")
        }
        if let fingerprint, targets.count > 1 {
            throw AppCacheError("\(targets.count) stored apps start with \(fingerprint). Give more of the fingerprint.")
        }
        for t in targets { try FileManager.default.removeItem(at: entry(t.fingerprint)) }
        return targets
    }

    static func size(of url: URL) -> Int64 {
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        while let f = e?.nextObject() as? URL {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }

    /// ISO 8601 with milliseconds: least-recently-used order needs more
    /// than whole seconds.
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date: \(text)"))
        }
        return d
    }
}
