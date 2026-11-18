import Foundation

/// The single source for "how big is this simulator when full" and "how much
/// does light save". The CLI and the menu-bar app both use it.
///
/// Why it exists: after `fast-ios off`, a running simulator gets its services
/// enabled again (`launchctl enable`), so both its disabled.plist and its live
/// launchd say "nothing is off". But enable does not start those services:
/// the simulator keeps running light until its next start. The menu-bar app
/// judged "full" from disabled.plist alone and saved that still-light
/// simulator's size (792 MB) as its full size, so after `on` it showed
/// "118 MB saved" while the real saving was about 2 GB. A measurement now
/// counts as full only when the simulator started after it was made full.
public enum Savings {
    /// Memory keeps climbing for about 3 minutes after a start; fast-ios's own
    /// measurements are taken then (README).
    public static let settleSeconds: TimeInterval = 180

    /// A full iPhone 18 Pro on iOS 27.0, 3 minutes after boot, measured with
    /// the footprint tool on 15 Nov 2026 (README). Used when this Mac has no
    /// measurement of its own.
    public static let estimatedFullBytes: Int64 = 2_845 * 1_048_576
    public static let estimateDescription = "a full iPhone 18 Pro on iOS 27.0 (2,845 MB), measured on another Mac"

    /// What fast-ios knows about one simulator at one moment.
    public struct Observation: Sendable, Equatable {
        public var udid: String
        public var runtime: String
        public var deviceType: String?
        public var isBooted: Bool
        /// Labels disabled in the simulator's disabled.plist.
        public var diskDisabled: Set<String>
        /// Labels its running launchd reports disabled; nil when not read.
        public var liveDisabled: Set<String>?
        public var measurement: SimMeasurement?
        /// Seconds since its launchd_sim started.
        public var bootAge: TimeInterval?
        /// When fast-ios turned its services back on while it ran (`off`).
        public var fullAfterRestartSince: Date?

        public init(udid: String, runtime: String, deviceType: String?, isBooted: Bool, diskDisabled: Set<String>,
                    liveDisabled: Set<String>? = nil, measurement: SimMeasurement? = nil, bootAge: TimeInterval? = nil,
                    fullAfterRestartSince: Date? = nil) {
            self.udid = udid; self.runtime = runtime; self.deviceType = deviceType; self.isBooted = isBooted
            self.diskDisabled = diskDisabled; self.liveDisabled = liveDisabled; self.measurement = measurement
            self.bootAge = bootAge; self.fullAfterRestartSince = fullAfterRestartSince
        }

        public init(_ device: SimDevice, diskDisabled: Set<String>, liveDisabled: Set<String>? = nil,
                    measurement: SimMeasurement? = nil, bootAge: TimeInterval? = nil, state: FastIOSState = StateStore.load()) {
            self.init(udid: device.udid, runtime: device.runtimeIdentifier, deviceType: device.deviceTypeIdentifier,
                      isBooted: device.isBooted, diskDisabled: diskDisabled, liveDisabled: liveDisabled,
                      measurement: measurement, bootAge: bootAge,
                      fullAfterRestartSince: state.fullAfterRestart?[device.udid])
        }

        /// Started before `off` turned its services back on: still light in
        /// memory, whatever the files say.
        public func startedBeforeMadeFull(now: Date = Date()) -> Bool {
            guard isBooted, let since = fullAfterRestartSince else { return false }
            guard let bootAge else { return true }  // unknown start: assume the worst
            return now.addingTimeInterval(-bootAge) < since
        }

        /// Running with services off right now (or still light until restart).
        public func isRunningLight(now: Date = Date()) -> Bool {
            let off = (isBooted ? liveDisabled : nil) ?? diskDisabled
            return !off.intersection(ServiceCatalog.slimmable).isEmpty || startedBeforeMadeFull(now: now)
        }

        public var isSettling: Bool { isBooted && (bootAge ?? .infinity) < Savings.settleSeconds }
    }

    /// True only when this measurement is a real full size: running, settled,
    /// nothing fast-ios manages is off on disk or in launchd, and it started
    /// after it was last made full.
    public static func isReallyFull(_ o: Observation, now: Date = Date()) -> Bool {
        guard o.isBooted, o.measurement != nil, let age = o.bootAge, age >= settleSeconds else { return false }
        guard o.diskDisabled.intersection(ServiceCatalog.managed).isEmpty else { return false }
        if let live = o.liveDisabled, !live.intersection(ServiceCatalog.slimmable).isEmpty { return false }
        return !o.startedBeforeMadeFull(now: now)
    }

    /// One simulator's saving: its full size minus what it uses now.
    public struct Saving: Sendable, Equatable {
        public let current: Int64
        public let baseline: FullBaseline
        /// Memory is still climbing: the saving will shrink a little.
        public let settling: Bool
        public var saved: Int64 { max(0, baseline.bytes - current) }
    }

    public static func saving(for o: Observation, store: BaselineStore) -> Saving? {
        guard o.isBooted, o.isRunningLight(), let m = o.measurement else { return nil }
        return Saving(current: m.bytes, baseline: store.baseline(udid: o.udid, runtime: o.runtime, deviceType: o.deviceType),
                      settling: o.isSettling)
    }

    /// Sums savings; the total's source is the weakest one in it.
    public struct Total: Sendable, Equatable {
        public var saved: Int64 = 0
        public var current: Int64 = 0
        public var full: Int64 = 0
        public var count = 0
        public var settling = false
        public var source: FullBaseline.Source = .estimated
    }

    public static func total(_ savings: [Saving]) -> Total? {
        guard !savings.isEmpty else { return nil }
        var t = Total()
        var rank = 0
        var newest = Date.distantPast
        for s in savings {
            t.saved += s.saved; t.current += s.current; t.full += s.baseline.bytes; t.count += 1
            t.settling = t.settling || s.settling
            switch s.baseline.source {
            case .measured(let d): newest = max(newest, d)
            case .sameModel(let d): rank = max(rank, 1); newest = max(newest, d)
            case .estimated: rank = 2
            }
        }
        t.source = rank == 2 ? .estimated : rank == 1 ? .sameModel(newest) : .measured(newest)
        return t
    }
}

/// A simulator's full size, and where that figure came from.
public struct FullBaseline: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Measured on this same simulator while it was really full.
        case measured(Date)
        /// Measured on another simulator of the same model and iOS version.
        case sameModel(Date)
        /// No measurement on this Mac: the published reference figure.
        case estimated
    }
    public let bytes: Int64
    public let source: Source

    public var isMeasured: Bool { if case .estimated = source { false } else { true } }
    /// "measured", "measured on the same model" or "estimated".
    public var label: String {
        switch source {
        case .measured: "measured"
        case .sameModel: "measured on the same model"
        case .estimated: "estimated"
        }
    }
}

/// Full sizes measured on this Mac, in stock-baselines.json beside
/// state.json. Version 2 entries passed `Savings.isReallyFull`; files without
/// a version were written by the menu-bar app under the old rule, which could
/// record a still-light simulator, so their entries are dropped on load.
public struct BaselineStore: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var bytes: Int64
        public var processes: Int
        public var runtime: String
        public var deviceType: String?
        public var measuredAt: Date
    }

    public static let currentVersion = 2
    public var version: Int? = BaselineStore.currentVersion
    public var entries: [String: Entry] = [:]

    public init() {}

    public static var url: URL {
        StateStore.url.deletingLastPathComponent().appendingPathComponent("stock-baselines.json")
    }

    public static func load(from url: URL = BaselineStore.url) -> BaselineStore {
        guard let data = try? Data(contentsOf: url) else { return BaselineStore() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let s = try? decoder.decode(BaselineStore.self, from: data), (s.version ?? 0) >= currentVersion else {
            return BaselineStore()
        }
        return s
    }

    public func save(to url: URL = BaselineStore.url) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Records each observation that is really full. One sample per minute
    /// per simulator. Returns true when something changed.
    @discardableResult
    public mutating func record(_ observations: [Savings.Observation], now: Date = Date()) -> Bool {
        var changed = false
        for o in observations where Savings.isReallyFull(o, now: now) {
            guard let m = o.measurement else { continue }
            if let old = entries[o.udid], now.timeIntervalSince(old.measuredAt) < 60 { continue }
            entries[o.udid] = Entry(bytes: m.bytes, processes: m.processes, runtime: o.runtime,
                                    deviceType: o.deviceType, measuredAt: now)
            changed = true
        }
        version = Self.currentVersion
        return changed
    }

    /// The same, for a device. Synchronous and cheap: no I/O beyond `load()`.
    public func baseline(for device: SimDevice) -> FullBaseline {
        baseline(udid: device.udid, runtime: device.runtimeIdentifier, deviceType: device.deviceTypeIdentifier)
    }

    /// The full size to compare with: this simulator's own measurement, else
    /// the newest of the same model and runtime, else the estimate.
    public func baseline(udid: String, runtime: String, deviceType: String?) -> FullBaseline {
        if let own = entries[udid] { return FullBaseline(bytes: own.bytes, source: .measured(own.measuredAt)) }
        let peers = entries.values.filter { $0.runtime == runtime && $0.deviceType == deviceType }
        if let peer = peers.max(by: { $0.measuredAt < $1.measuredAt }) {
            return FullBaseline(bytes: peer.bytes, source: .sameModel(peer.measuredAt))
        }
        return FullBaseline(bytes: Savings.estimatedFullBytes, source: .estimated)
    }
}
