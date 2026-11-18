import Foundation

// The JSON that `--json` prints and that the MCP tools return as
// `structuredContent`. Field names are part of the public interface: add
// fields freely, never rename or remove one without bumping `schemaVersion`.
// Optional fields marked @EncodeNull are always present, as `null` when unknown.

/// Any JSON value. Used for MCP messages, tool arguments and schemas.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] } else { return nil }
    }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

/// Encodes an optional as `null` instead of leaving the key out.
@propertyWrapper
public struct EncodeNull<T: Encodable & Sendable>: Encodable, Sendable {
    public var wrappedValue: T?
    public init(wrappedValue: T?) { self.wrappedValue = wrappedValue }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let v = wrappedValue { try c.encode(v) } else { try c.encodeNil() }
    }
}

public enum JSONOutput {
    /// Bumped only when a field is renamed or removed.
    public static let schemaVersion = 1

    public static func encode<T: Encodable>(_ value: T, pretty: Bool) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                                          : [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func value<T: Encodable>(_ value: T) throws -> JSONValue {
        if let v = value as? JSONValue { return v }
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// `{"schemaVersion": 1, "error": {"code": …, "message": …}}`
    public static func error(_ error: Error) -> JSONValue {
        let (code, message) = classify(error)
        var body: [String: JSONValue] = ["code": .string(code), "message": .string(message)]
        // A refused lease (from `run`) also says what to do next.
        if let r = error as? LeaseRefusal, !r.nextStep.isEmpty { body["nextStep"] = .string(r.nextStep) }
        return ["schemaVersion": .int(Int64(schemaVersion)), "error": .object(body)]
    }

    /// Stable error codes: usage, invalid_arguments, simulator, app, command_failed, internal.
    public static func classify(_ error: Error) -> (code: String, message: String) {
        switch error {
        case let e as UsageError: ("usage", e.message)
        case let e as InvalidArguments: ("invalid_arguments", e.message)
        case let e as SimctlError: ("simulator", e.message)
        case let e as InspectError: ("app", e.message)
        case let e as ShellError: ("command_failed", e.localizedDescription)
        default: ("internal", error.localizedDescription)
        }
    }
}

public struct UsageError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct InvalidArguments: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Output types, one per command

public struct SimulatorRef: Encodable, Sendable {
    public let udid: String
    public let name: String
    /// "iOS 27.0"
    public let runtime: String
    public let runtimeIdentifier: String
    @EncodeNull public var deviceType: String?
    /// simctl's state before the command ran: "Booted", "Shutdown", …
    public let state: String

    public init(_ d: SimDevice) {
        udid = d.udid; name = d.name; runtime = d.runtimeName
        runtimeIdentifier = d.runtimeIdentifier; deviceType = d.deviceTypeIdentifier; state = d.state
    }
}

public struct SimulatorStatus: Encodable, Sendable {
    public let udid: String
    public let name: String
    public let runtime: String
    public let runtimeIdentifier: String
    @EncodeNull public var deviceType: String?
    public let state: String
    /// True when at least one catalog service is disabled.
    public let slim: Bool
    /// Catalog services disabled in the simulator's launchd store.
    public let disabledCount: Int
    /// The fast-ios profile applied, "set outside fast-ios", or null for stock.
    @EncodeNull public var profileName: String?
    /// Booted simulators only: processes under its launchd_sim.
    @EncodeNull public var processes: Int?
    /// Booted simulators only: summed phys_footprint (top's MEM column), bytes.
    @EncodeNull public var memoryBytes: Int64?
}

public struct StatusOutput: Encodable, Sendable {
    public var schemaVersion = JSONOutput.schemaVersion
    /// The custom device set, or null for the default set.
    @EncodeNull public var deviceSet: String?
    public let simulators: [SimulatorStatus]
}

public struct MatchedRule: Encodable, Sendable {
    public let trigger: String
    public let reason: String
    public let keep: [String]
}

public struct ProfileOutput: Encodable, Sendable {
    public var schemaVersion = JSONOutput.schemaVersion
    /// The .app that was read.
    public let app: String
    @EncodeNull public var bundleIdentifier: String?
    public let profile: SlimProfile
    public let matchedRules: [MatchedRule]
    /// Size of the slimmable catalog: keep + disable counts add up to it.
    public let catalogCount: Int
    public let neverDisabled: [String]
}

public struct ProfileSummary: Encodable, Sendable {
    public let name: String
    @EncodeNull public var appPath: String?
    public let keepCount: Int
    public let disableCount: Int
    public init(_ p: SlimProfile) {
        name = p.name; appPath = p.appPath; keepCount = p.keep.count; disableCount = p.disable.count
    }
}

public struct SlimOutput: Encodable, Sendable {
    public var schemaVersion = JSONOutput.schemaVersion
    public let simulator: SimulatorRef
    public let profile: ProfileSummary
    /// Labels newly disabled by this run.
    public let disabled: [String]
    /// Labels re-enabled by this run (the new profile keeps them).
    public let reenabled: [String]
    /// True when the simulator is booted after the run.
    public let booted: Bool
    /// True when booted and launchd reports every override. False when left shut down.
    public let verified: Bool
    /// Overrides launchd does not report after boot. Empty when verified or shut down.
    public let notHonoured: [String]
    /// Progress lines, in order.
    public let log: [String]
}

public struct OffOutput: Encodable, Sendable {
    public var schemaVersion = JSONOutput.schemaVersion
    public let simulator: SimulatorRef
    public let reenabled: [String]
    /// True when nothing had to change.
    public let alreadyStock: Bool
    public let booted: Bool
    public let log: [String]
}

public struct MeasuredProcess: Encodable, Sendable {
    public let pid: Int32
    public let name: String
    /// `footprint` bytes.
    public let bytes: Int64
}

public struct MeasureOutput: Encodable, Sendable {
    public var schemaVersion = JSONOutput.schemaVersion
    public let simulator: SimulatorRef
    public let processCount: Int
    /// Summed `footprint` of every process, bytes.
    public let totalBytes: Int64
    /// Every process, largest first.
    public let processes: [MeasuredProcess]
}

public struct CatalogService: Encodable, Sendable {
    public let label: String
    public let description: String
}

public struct CatalogCategory: Encodable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    /// What stops working while this category is off.
    public let downside: String
    public let approxMemoryMB: Int
    public let services: [CatalogService]
}

public struct ProtectedService: Encodable, Sendable {
    public let label: String
    public let reason: String
}

public struct CatalogOutput: Encodable, Sendable {
    public var schemaVersion = JSONOutput.schemaVersion
    public let slimmableCount: Int
    public let categories: [CatalogCategory]
    public let neverDisabled: [ProtectedService]
}

/// `watch --json` prints one of these per line (NDJSON).
public struct WatchEvent: Encodable, Sendable {
    public var schemaVersion = JSONOutput.schemaVersion
    /// "watching", "slimmed", "skipped" or "error".
    public let event: String
    @EncodeNull public var udid: String?
    @EncodeNull public var message: String?
    @EncodeNull public var disabledCount: Int?
    @EncodeNull public var setFolders: [String]?
    @EncodeNull public var profile: ProfileSummary?

    public init(event: String, udid: String? = nil, message: String? = nil, disabledCount: Int? = nil,
                setFolders: [String]? = nil, profile: ProfileSummary? = nil) {
        self.event = event; self.udid = udid; self.message = message; self.disabledCount = disabledCount
        self.setFolders = setFolders; self.profile = profile
    }
}
