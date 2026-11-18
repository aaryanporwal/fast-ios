import Foundation

// lease, release and leases as MCP tools; the same entries give the CLI
// commands their --json output.

public struct LeaseToolOutput: Encodable, Sendable {
    public var schemaVersion = JSONOutput.schemaVersion
    /// "leased" or "refused".
    public let status: String
    @EncodeNull public var udid: String?
    @EncodeNull public var name: String?
    @EncodeNull public var deviceSet: String?
    @EncodeNull public var runtime: String?
    @EncodeNull public var deviceType: String?
    @EncodeNull public var profile: String?
    /// "reused-booted", "booted-shut-down" or "created".
    @EncodeNull public var source: String?
    @EncodeNull public var owner: String?
    @EncodeNull public var ownerPid: Int?
    @EncodeNull public var expiresAt: String?
    public let waitedSeconds: Double
    @EncodeNull public var prepareSeconds: Double?
    /// True when the simulator was cloned from a slim template.
    public var cloned = false
    /// Simulators that failed to boot or answer and were retired first.
    public var replaced: [Replacement] = []
    /// Refusals: "memory" or "queue".
    @EncodeNull public var reason: String?
    @EncodeNull public var detail: String?
    @EncodeNull public var queuePosition: Int?
    @EncodeNull public var memory: MemoryStatus?
    @EncodeNull public var policy: AdmissionPolicy?
    /// Refusals: what uses the memory, and what to do next (exact commands).
    @EncodeNull public var usage: [String]?
    @EncodeNull public var nextStep: String?

    init(_ r: LeaseResult) {
        status = r.status; udid = r.udid; name = r.name; deviceSet = r.deviceSet; runtime = r.runtime
        deviceType = r.deviceType; profile = r.profile; source = r.source.rawValue; owner = r.owner
        ownerPid = r.ownerPid.map(Int.init); expiresAt = iso(r.expiresAt); waitedSeconds = r.waitedSeconds
        prepareSeconds = r.prepareSeconds
        cloned = r.cloned; replaced = r.replaced
    }

    init(_ r: LeaseRefusal) {
        status = r.status; waitedSeconds = r.waitedSeconds; reason = r.reason; detail = r.detail
        queuePosition = r.queuePosition; memory = r.memory; policy = r.policy
        deviceSet = Simctl.deviceSet
        usage = r.usage; nextStep = r.nextStep
    }
}

public struct ReleaseToolOutput: Encodable, Sendable {
    public var schemaVersion = JSONOutput.schemaVersion
    public let udid: String
    /// "released" or "not-leased".
    public let status: String
}

public struct LeasesToolOutput: Encodable, Sendable {
    public struct Row: Encodable, Sendable {
        public let udid: String
        @EncodeNull public var name: String?
        public let owner: String
        @EncodeNull public var ownerPid: Int?
        @EncodeNull public var ownerAlive: Bool?
        public let status: String
        public let profile: String
        public let leasedAt: String
        public let expiresAt: String
        public let remainingSeconds: Int
    }
    public struct PoolRow: Encodable, Sendable {
        public let udid: String
        public let name: String
        @EncodeNull public var deviceSet: String?
        public let runtime: String
        public let deviceType: String
        public let createdAt: String
        public let adopted: Bool
        public let draining: Bool
    }
    public struct QueueRow: Encodable, Sendable {
        public let owner: String
        public let pid: Int
        public let enqueuedAt: String
    }
    public var schemaVersion = JSONOutput.schemaVersion
    @EncodeNull public var deviceSet: String?
    public let leases: [Row]
    public let pool: [PoolRow]
    public let queue: [QueueRow]
    /// Leases this call freed because their TTL passed or their owner exited.
    public let released: [String]
    public let memory: MemoryStatus
    /// Free pool simulators this call shut down: udid and reason (memory, idle, over-size).
    public var shutDown: [PoolTrim.Decision] = []
    /// One line per pool simulator of this device set: what it does and what happens next.
    public var poolStatus: [String] = []
}

func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

extension FastIOSCommands {
    /// Builds the request from tool arguments; shared by the CLI text path.
    public static func leaseRequest(_ a: ToolArguments) async throws -> LeaseRequest {
        let (profile, _) = try await resolveProfile(app: a.optionalString("app"), keep: a.strings("keep"), full: a.bool("full"))
        var req = LeaseRequest(profile: profile)
        req.runtime = a.optionalString("runtime")
        req.deviceType = a.optionalString("deviceType")
        if let s = a.optionalString("ttl") {
            guard let t = parseDuration(s) else { throw InvalidArguments("ttl must look like 90s, 30m or 2h.") }
            req.ttl = t
        }
        if let s = a.optionalString("timeout") {
            guard let t = parseDuration(s) else { throw InvalidArguments("timeout must look like 90s, 30m or 2h.") }
            req.timeout = t
        }
        req.owner = a.optionalString("owner")
        req.ownerPid = a.int("pid").map { Int32($0) }
        req.policy = AdmissionPolicy(needMB: a.int("needMb"), reserveMB: a.int("reserveMb"), maxPressure: a.optionalString("maxPressure"))
        req.allowExisting = a.bool("allowExisting")
        return req
    }

    public static func lease(_ a: ToolArguments, log: Log = { _ in }) async throws -> LeaseToolOutput {
        let req = try await leaseRequest(a)
        do {
            return LeaseToolOutput(try await LeaseManager.lease(req, log: log))
        } catch let refusal as LeaseRefusal {
            return LeaseToolOutput(refusal)
        }
    }

    public static func release(udid: String, shutdown: Bool) async throws -> ReleaseToolOutput {
        let had = try await LeaseManager.release(udid, shutdown: shutdown)
        return ReleaseToolOutput(udid: udid, status: had ? "released" : "not-leased")
    }

    public static func leases() async throws -> LeasesToolOutput {
        let l = try await LeaseManager.list()
        return LeasesToolOutput(
            deviceSet: Simctl.deviceSet,
            leases: l.leases.map {
                .init(udid: $0.udid, name: $0.name, owner: $0.owner, ownerPid: $0.ownerPid.map(Int.init), ownerAlive: $0.ownerAlive,
                      status: $0.status, profile: $0.profile, leasedAt: iso($0.leasedAt), expiresAt: iso($0.expiresAt),
                      remainingSeconds: $0.remainingSeconds)
            },
            pool: l.pool.map {
                .init(udid: $0.udid, name: $0.name, deviceSet: $0.deviceSet.isEmpty ? nil : $0.deviceSet, runtime: $0.runtime,
                      deviceType: $0.deviceType, createdAt: iso($0.createdAt), adopted: $0.adopted, draining: $0.draining)
            },
            queue: l.queue.map { .init(owner: $0.owner, pid: Int($0.process.pid), enqueuedAt: iso($0.enqueuedAt)) },
            released: l.released, memory: l.memory, shutDown: l.shutDown, poolStatus: l.poolStatus)
    }

    /// "90s", "30m", "2h", or a bare number of minutes.
    public static func parseDuration(_ s: String) -> TimeInterval? {
        let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600]
        if let last = s.last, let unit = units[last], let n = Double(s.dropLast()) { return n * unit }
        return Double(s).map { $0 * 60 }
    }
}

extension ToolArguments {
    public func int(_ key: String) -> Int? {
        if case .int(let n)? = raw[key] { return Int(n) }
        return nil
    }
}

extension MCPTools {
    static let number = Schema.typed("number", nil)
    static let memorySchema = Schema.object([
        "availableMB": Schema.integer("Free + inactive + speculative + purgeable memory."),
        "totalMB": Schema.integer(),
        "pressure": Schema.string("Kernel memory pressure: normal, warning or critical."),
    ], required: ["availableMB", "totalMB", "pressure"])
    static let policySchema = Schema.object([
        "needMB": Schema.integer(), "reserveMB": Schema.integer(), "maxPressure": Schema.string(),
    ], required: ["needMB", "reserveMB", "maxPressure"])
    static let nullableMemory: JSONValue = ["type": ["object", "null"], "properties": memorySchema["properties"] ?? [:]]
    static let nullablePolicy: JSONValue = ["type": ["object", "null"], "properties": policySchema["properties"] ?? [:]]

    static let lease = MCPTool(
        name: "lease", title: "Lease a light simulator",
        description: "Get a light, running simulator for this agent instead of booting your own. Reuses a free booted pool simulator (seconds), boots a shut-down one, or creates one (about 1 to 2 min). The lease ends at release, after ttl, or when the owner process exits (pid, else the caller). While the Mac is short on memory a new boot waits in a first-come queue; after timeout the result has status \"refused\" with reason and detail. Only simulators fast-ios created are leased.",
        inputSchema: Schema.object([
            "app": Schema.string("Built app or folder: the simulator is made light for it."),
            "keep": keepArg,
            "full": Schema.boolean("Turn off every catalog service when no app is given."),
            "runtime": Schema.string("Runtime identifier, \"iOS 27.0\" or \"27.0\". Default: newest iOS."),
            "deviceType": Schema.string("Device type identifier or name. Default: newest iPhone Pro."),
            "ttl": Schema.string("Lease length: 90s, 30m (default), 2h."),
            "owner": Schema.string("Free-text owner id shown by leases."),
            "pid": Schema.integer("Process whose exit ends the lease."),
            "timeout": Schema.string("How long to wait in the queue: default 5m."),
            "needMb": Schema.integer("Memory one more simulator needs (default 1500)."),
            "reserveMb": Schema.integer("Memory that must stay free (default 2048)."),
            "maxPressure": Schema.string("Highest kernel pressure that admits a boot: normal (default) or warning."),
            "allowExisting": Schema.boolean("Also lease shut-down simulators fast-ios did not create."),
            "deviceSet": deviceSetArg,
        ]),
        outputSchema: Schema.object([
            "schemaVersion": Schema.integer(), "status": Schema.string("leased or refused"),
            "udid": Schema.nullable("string"), "name": Schema.nullable("string"), "deviceSet": Schema.nullable("string"),
            "runtime": Schema.nullable("string"), "deviceType": Schema.nullable("string"), "profile": Schema.nullable("string"),
            "source": Schema.nullable("string", "reused-booted, booted-shut-down or created"),
            "owner": Schema.nullable("string"), "ownerPid": Schema.nullable("integer"), "expiresAt": Schema.nullable("string"),
            "waitedSeconds": number, "prepareSeconds": Schema.nullable("number"),
            "cloned": Schema.boolean("Copied from a light template (skips first-start setup)."),
            "replaced": replacedSchema,
            "reason": Schema.nullable("string", "memory or queue"), "detail": Schema.nullable("string"),
            "queuePosition": Schema.nullable("integer"), "memory": nullableMemory, "policy": nullablePolicy,
            "usage": ["type": ["array", "null"], "items": Schema.string(), "description": "Refused: what uses the memory, in plain words."],
            "nextStep": Schema.nullable("string", "Refused: what to do now, with the exact flag or command."),
        ], required: ["schemaVersion", "status", "udid", "waitedSeconds"]),
        annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false]
    ) { args in try await FastIOSCommands.lease(args) }

    static let release = MCPTool(
        name: "release", title: "Release a leased simulator",
        description: "End a lease. The simulator stays booted for the next lease unless shutdown is true; idle pool simulators beyond one are shut down.",
        inputSchema: Schema.object([
            "udid": Schema.string("The leased simulator."),
            "shutdown": Schema.boolean("Shut the simulator down now."),
            "deviceSet": deviceSetArg,
        ], required: ["udid"]),
        outputSchema: Schema.object([
            "schemaVersion": Schema.integer(), "udid": Schema.string(), "status": Schema.string("released or not-leased"),
        ], required: ["schemaVersion", "udid", "status"]),
        annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        positional: ["udid"]
    ) { args in try await FastIOSCommands.release(udid: try args.string("udid"), shutdown: args.bool("shutdown")) }

    static let leases = MCPTool(
        name: "leases", title: "List leases",
        description: "Who holds which simulator, the pool fast-ios created, the queue, and the Mac's memory. Also frees leases whose TTL passed or whose owner exited, and shuts down free pool simulators fast-ios created while memory is short, after the idle limit (30 min) or beyond the warm size.",
        inputSchema: Schema.object(["deviceSet": deviceSetArg]),
        outputSchema: Schema.object([
            "schemaVersion": Schema.integer(), "deviceSet": Schema.nullable("string"),
            "leases": Schema.array(Schema.object([
                "udid": Schema.string(), "name": Schema.nullable("string"), "owner": Schema.string(),
                "ownerPid": Schema.nullable("integer"), "ownerAlive": Schema.nullable("boolean"),
                "status": Schema.string("preparing or ready"), "profile": Schema.string(),
                "leasedAt": Schema.string(), "expiresAt": Schema.string(), "remainingSeconds": Schema.integer(),
            ], required: ["udid", "name", "owner", "ownerPid", "ownerAlive", "status", "profile", "leasedAt", "expiresAt", "remainingSeconds"])),
            "pool": Schema.array(Schema.object([
                "udid": Schema.string(), "name": Schema.string(), "deviceSet": Schema.nullable("string"),
                "runtime": Schema.string(), "deviceType": Schema.string(), "createdAt": Schema.string(),
                "adopted": Schema.boolean(), "draining": Schema.boolean(),
            ], required: ["udid", "name", "deviceSet", "runtime", "deviceType", "createdAt", "adopted", "draining"])),
            "queue": Schema.array(Schema.object([
                "owner": Schema.string(), "pid": Schema.integer(), "enqueuedAt": Schema.string(),
            ], required: ["owner", "pid", "enqueuedAt"])),
            "released": strings, "memory": memorySchema,
            "shutDown": Schema.array(Schema.object(["udid": Schema.string(), "reason": Schema.string("memory, idle or over-size")],
                                                   required: ["udid", "reason"]),
                                     "Free pool simulators this call shut down, and why."),
            "poolStatus": Schema.array(Schema.string(), "One line per pool simulator: what it does and what happens next."),
        ], required: ["schemaVersion", "deviceSet", "leases", "pool", "queue", "released", "memory"]),
        // Not read-only: listing frees leases whose owner exited.
        annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
    ) { _ in try await FastIOSCommands.leases() }
}
