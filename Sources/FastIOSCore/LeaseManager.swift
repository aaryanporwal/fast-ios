import Foundation

public struct LeaseRequest: Sendable {
    public var profile: SlimProfile
    /// Runtime identifier, "iOS 27.0" or "27.0". nil: newest iOS runtime.
    public var runtime: String?
    /// Device type identifier or name. nil: newest iPhone Pro (not Max).
    public var deviceType: String?
    public var ttl: TimeInterval = 30 * 60
    public var owner: String?
    /// Pid whose exit ends the lease. nil: the caller (first non-shell ancestor).
    public var ownerPid: Int32?
    /// How long to wait while the Mac itself is short of memory (pressure
    /// above `policy.maxPressure`, or too little free). 0, the default:
    /// refuse at once and say what to do (`--wait-for-memory`).
    public var memoryWait: TimeInterval = 0
    /// How long to wait behind other requests and simulators already
    /// starting, when memory alone would allow the boot. At least
    /// `memoryWait`.
    public var queueWait: TimeInterval = LeaseManager.defaultQueueWait
    public var policy = AdmissionPolicy()
    /// Also lease shut-down simulators fast-ios did not create.
    public var allowExisting = false

    public init(profile: SlimProfile) { self.profile = profile }
}

public struct LeaseResult: Codable, Sendable {
    public enum Source: String, Codable, Sendable { case reusedBooted = "reused-booted", bootedShutdown = "booted-shut-down", created }
    public let status: String
    public let udid: String
    public let name: String
    public let deviceSet: String?
    public let runtime: String
    public let deviceType: String
    public let profile: String
    public let source: Source
    public let owner: String
    public let ownerPid: Int32?
    public let expiresAt: Date
    public let waitedSeconds: Double
    public let prepareSeconds: Double
    /// True when the simulator was cloned from a slim template.
    public var cloned = false
    /// Simulators that failed to boot or answer and were retired first.
    public var replaced: [Replacement] = []
}

public struct LeaseRefusal: Error, Codable, Sendable, LocalizedError {
    public let status: String
    /// "memory" or "queue" (others are ahead and the wait timed out).
    public let reason: String
    public let detail: String
    public let waitedSeconds: Double
    public let queuePosition: Int?
    public let memory: MemoryStatus
    public let policy: AdmissionPolicy
    /// What uses the memory, in plain words (running simulators, largest apps).
    public var usage: [String] = []
    /// What to do now, with the exact command or flag.
    public var nextStep: String = ""
    /// Memory refusals: the running simulators and the largest apps.
    public var simulators: [RunningSimulator] = []
    public var largestApps: [AppMemory] = []
    public var errorDescription: String? {
        let lines = [headline] + usage + (nextStep.isEmpty ? [] : ["Next: \(nextStep)"])
        return lines.joined(separator: "\n")
    }

    /// "No simulator was started: <why>", with the wait when there was one.
    public var headline: String {
        let s = sentence
        if waitedSeconds < 1 { return "No simulator was started: " + s }
        return "No simulator was started: after waiting \(Int(waitedSeconds)) s, " + s.prefix(1).lowercased() + s.dropFirst()
    }

    /// The reason as a sentence.
    var sentence: String {
        guard reason == "memory" else { return detail.prefix(1).uppercased() + detail.dropFirst() + "." }
        return MemoryAdvice.sentence(memory, policy: policy, pendingBoots: 0)
    }
}

public struct LeaseListing: Codable, Sendable {
    public struct Row: Codable, Sendable {
        public let udid: String
        public let name: String?
        public let owner: String
        public let ownerPid: Int32?
        public let ownerAlive: Bool?
        public let status: String
        public let profile: String
        public let leasedAt: Date
        public let expiresAt: Date
        public let remainingSeconds: Int
    }
    public let leases: [Row]
    public let pool: [PoolDevice]
    public let queue: [LeaseTicket]
    public let released: [String]
    public let memory: MemoryStatus
    /// Free pool simulators this call shut down, and why.
    public var shutDown: [PoolTrim.Decision] = []
    /// One line per pool simulator of this set: what it does and what happens next.
    public var poolStatus: [String] = []
}

public enum LeaseManager {
    static let poolPrefix = "fast-ios-lease-"
    static var currentSet: String { Simctl.deviceSet ?? "" }

    /// Leases a slim, booted simulator: a free booted pool simulator first,
    /// a shut-down one second, a new one last. New boots wait in a FIFO queue
    /// while memory is short.
    ///
    /// A simulator that does not boot within the adaptive timeout, fails to
    /// boot, or boots without launchd answering is retired (deleted when
    /// fast-ios created it, else only dropped from the pool) and the lease is
    /// tried again, up to `maxAttempts` times. Each one is in `replaced`.
    public static func lease(_ req: LeaseRequest, log: Log = { _ in }) async throws -> LeaseResult {
        let (result, replaced) = try await SimHealth.withReplacement(
            maxAttempts: maxAttempts,
            attempt: { n in
                if n > 1 { log("attempt \(n) of \(maxAttempts)") }
                return try await leaseOnce(req, log: log)
            },
            retire: { failed in await retire(failed, log: log) })
        var r = result
        r.replaced = replaced
        return r
    }

    /// How long a request waits behind others whose simulators are starting.
    /// Waiting for the Mac itself to free memory is `LeaseRequest.memoryWait`.
    public static let defaultQueueWait: TimeInterval = 300

    /// Also gets the waiting lines. `--json` sets it to stderr, so an agent
    /// sees a wait while stdout stays one JSON document.
    @TaskLocal public static var waitLog: Log?

    /// How often a waiting request says it is still waiting.
    static let progressEvery: TimeInterval = 30

    /// "30 s", "5 min", "1 min 30 s".
    public static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s) s" }
        return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s"
    }

    static var maxAttempts: Int {
        ProcessInfo.processInfo.environment["FASTIOS_MAX_ATTEMPTS"].flatMap(Int.init) ?? 3
    }

    /// Takes a failed simulator out of service: shut down, deleted if
    /// fast-ios created it, removed from the pool and from any lease.
    static func retire(_ failed: BootFailureContext, log: Log) async -> Replacement {
        let delete = SimHealth.shouldDelete(adopted: failed.adopted)
        log("Simulator \(failed.udid) did not start properly (\(failed.failure.localizedDescription)); \(delete ? "deleting it and trying another" : "leaving it alone and trying another").")
        _ = try? await Simctl.simctl("shutdown", failed.udid, check: false)
        if delete {
            _ = try? await Simctl.simctl("delete", failed.udid, check: false)
            try? FileManager.default.removeItem(at: DisabledStore.folder(failed.udid))
            try? StateStore.update { $0.devices[failed.udid] = nil }
        }
        _ = try? LeaseStore.withLock { state in
            state.pool[failed.udid] = nil
            state.leases[failed.udid] = nil
        }
        return Replacement(udid: failed.udid, reason: failed.failure.reason,
                           detail: failed.failure.localizedDescription, deleted: delete)
    }

    static func leaseOnce(_ req: LeaseRequest, log: Log) async throws -> LeaseResult {
        let started = Date()
        let (runtime, deviceType) = try await resolveTarget(runtime: req.runtime, deviceType: req.deviceType)
        let me = ProcessRef.current
        let ownerProcess = req.ownerPid.flatMap(ProcessRef.of) ?? ProcessInfoLite.ownerAncestor()
        let owner = req.owner ?? ownerProcess.map { "\($0.name)[\($0.pid)]" } ?? "pid \(me.pid)"
        let set = currentSet
        let ticket = LeaseTicket(id: UUID(), process: me, owner: owner, enqueuedAt: started, deviceSet: set)

        try LeaseStore.withLock { state in
            state.reap()
            state.queue.append(ticket)
        }
        defer { _ = try? LeaseStore.withLock { state in state.queue.removeAll { $0.id == ticket.id } } }

        var lastWait = ""
        var lastProgress = Date.distantPast
        let echo = Self.waitLog
        func say(_ line: String) { log(line); echo?(line) }
        while true {
            let devices = try await Simctl.listDevices()
            let memory = MemoryStatus.read()
            let decision: Decision = try LeaseStore.withLock { state in
                state.reap()
                let byUDID = Dictionary(devices.map { ($0.udid, $0) }, uniquingKeysWith: { a, _ in a })
                // Forget pool simulators of this set that someone deleted.
                for (udid, d) in state.pool where d.deviceSet == set && byUDID[udid] == nil && state.leases[udid] == nil {
                    state.pool[udid] = nil
                }
                let position = state.queue.filter { ($0.deviceSet ?? "") == set }.firstIndex { $0.id == ticket.id } ?? 0
                func claim(_ udid: String) -> Lease {
                    let lease = Lease(udid: udid, owner: owner, ownerProcess: ownerProcess, preparer: me, deviceSet: set,
                                      leasedAt: Date(), expiresAt: Date().addingTimeInterval(req.ttl),
                                      profileName: req.profile.name, status: .preparing)
                    state.leases[udid] = lease
                    state.queue.removeAll { $0.id == ticket.id }
                    return lease
                }
                let free = state.pool.values.filter {
                    $0.deviceSet == set && $0.runtime == runtime && $0.deviceType == deviceType
                        && !$0.draining && state.leases[$0.udid] == nil && byUDID[$0.udid]?.isAvailable == true
                }.sorted { $0.createdAt < $1.createdAt }

                // A free booted simulator costs no new memory: take it even
                // when others are queued for a boot.
                if let d = free.first(where: { byUDID[$0.udid]?.isBooted == true }) {
                    _ = claim(d.udid)
                    return .use(d.udid, .reusedBooted)
                }
                // Free memory held by an idle simulator of another kind.
                let idle = state.pool.values.first {
                    $0.deviceSet == set && !$0.draining && state.leases[$0.udid] == nil && byUDID[$0.udid]?.isBooted == true
                }
                let pending = state.leases.values.filter { $0.status == .preparing }.count
                switch admission(position: position, pending: pending, memory: memory, policy: req.policy, idle: idle?.udid) {
                case .go: break
                case .reclaim(let udid):
                    state.pool[udid]?.draining = true
                    return .reclaim(udid)
                case .wait(let reason, let detail):
                    return .wait(reason: reason, detail: detail, position: position)
                }
                if let d = free.first(where: { byUDID[$0.udid]?.state == "Shutdown" }) {
                    _ = claim(d.udid)
                    return .use(d.udid, .bootedShutdown)
                }
                if req.allowExisting, let d = devices.first(where: {
                    $0.state == "Shutdown" && $0.isAvailable && $0.runtimeIdentifier == runtime
                        && $0.deviceTypeIdentifier == deviceType && state.pool[$0.udid] == nil && state.leases[$0.udid] == nil
                }) {
                    state.pool[d.udid] = PoolDevice(udid: d.udid, name: d.name, deviceSet: set, runtime: runtime,
                                                    deviceType: deviceType, createdAt: Date(), adopted: true)
                    _ = claim(d.udid)
                    return .use(d.udid, .bootedShutdown)
                }
                let placeholder = "pending-\(UUID().uuidString)"
                _ = claim(placeholder)
                return .create(placeholder)
            }

            switch decision {
            case .wait(let reason, let detail, let position):
                let waited = Date().timeIntervalSince(started)
                // Waiting only helps when asked for (memory) or when others'
                // simulators are about to finish starting (queue).
                let wait = Self.waitLimit(reason: reason, req)
                if waited >= wait {
                    throw await refusal(reason: reason, detail: detail, waited: waited, position: position,
                                        memory: memory, req: req)
                }
                // Say why and for how long at once, then about every 30 s, so
                // an agent or a person never stares at one silent line.
                let limit = Self.duration(wait)
                if detail != lastWait {
                    let why = reason == "memory"
                        ? "Waiting for memory to start a new simulator. " + MemoryAdvice.sentence(memory, policy: req.policy, pendingBoots: 0)
                        : "Waiting to start a new simulator: \(detail)."
                    say("\(why) Gives up after \(limit)\(reason == "memory" ? "; change that with --wait-for-memory" : "").")
                    lastWait = detail; lastProgress = Date()
                } else if Date().timeIntervalSince(lastProgress) >= Self.progressEvery {
                    say("Still waiting: \(Int(waited)) s of \(limit). Memory pressure \(memory.pressure), \(memory.availableMB) MB free\(reason == "memory" ? "" : "; " + detail).")
                    lastProgress = Date()
                }
                try await Task.sleep(for: .seconds(1))
            case .reclaim(let udid):
                log("Shutting down idle simulator \(udid) to free memory…")
                _ = try? await Simctl.shutdownAndWait(udid)
                try LeaseStore.withLock { $0.pool[udid]?.draining = false }
            case .use(let udid, let source):
                return try await prepare(udid: udid, source: source, req: req, owner: owner, ownerPid: ownerProcess?.pid,
                                         started: started, set: set, runtime: runtime, deviceType: deviceType, log: log)
            case .create(let placeholder):
                let udid: String
                let cloned: Bool
                do {
                    let name = poolPrefix + String(UUID().uuidString.prefix(8)).lowercased()
                    (udid, cloned) = try await Templates.makeDevice(name: name, runtime: runtime, deviceType: deviceType, log: log)
                    try LeaseStore.withLock { state in
                        state.pool[udid] = PoolDevice(udid: udid, name: name, deviceSet: set, runtime: runtime,
                                                      deviceType: deviceType, createdAt: Date(), adopted: false)
                        if var lease = state.leases.removeValue(forKey: placeholder) {
                            lease.udid = udid
                            state.leases[udid] = lease
                        }
                    }
                } catch {
                    _ = try? LeaseStore.withLock { $0.leases[placeholder] = nil }
                    throw error
                }
                var result = try await prepare(udid: udid, source: .created, req: req, owner: owner, ownerPid: ownerProcess?.pid,
                                               started: started, set: set, runtime: runtime, deviceType: deviceType, log: log)
                result.cloned = cloned
                if !cloned { Templates.scheduleBuild(runtime: runtime, deviceType: deviceType, policy: req.policy, log: log) }
                return result
            }
        }
    }

    enum Admission: Equatable {
        case go
        case reclaim(String)
        /// reason "memory": the Mac itself is short, and only `memoryWait`
        /// waits. reason "queue": others go first or are still starting.
        case wait(reason: String, detail: String)
    }

    /// Whether a new boot may start now. `position` is this request's place
    /// in the queue, `pending` the boots already under way, `idle` a free
    /// running pool simulator of another kind that could be shut down.
    static func admission(position: Int, pending: Int, memory: MemoryStatus, policy: AdmissionPolicy,
                          idle: String?) -> Admission {
        // The Mac itself is short: waiting for other agents does not help.
        let macShort = !policy.admits(memory, pendingBoots: 0)
        let short = Admission.wait(reason: "memory", detail: policy.reason(memory, pendingBoots: 0))
        guard position == 0 else {
            if macShort && idle == nil { return short }
            let ahead = position == 1 ? "1 other request for a new simulator was" : "\(position) other requests for a new simulator were"
            return .wait(reason: "queue", detail: "\(ahead) still ahead in the queue")
        }
        if policy.admits(memory, pendingBoots: pending) { return .go }
        if let idle { return .reclaim(idle) }
        if macShort { return short }
        // Memory is enough for one more, but not also for the ones already
        // starting: wait for them to finish.
        let starting = pending == 1 ? "1 other simulator was" : "\(pending) other simulators were"
        return .wait(reason: "queue", detail: "\(starting) still starting, and there is memory for only one more at a time")
    }

    /// How long a request waits for `reason` before it is refused.
    static func waitLimit(reason: String, _ req: LeaseRequest) -> TimeInterval {
        reason == "memory" ? req.memoryWait : max(req.memoryWait, req.queueWait)
    }

    /// The refusal, with what uses the memory and the choices, read now.
    static func refusal(reason: String, detail: String, waited: TimeInterval, position: Int,
                        memory: MemoryStatus, req: LeaseRequest) async -> LeaseRefusal {
        var r = LeaseRefusal(status: "refused", reason: reason, detail: detail, waitedSeconds: waited.rounded(),
                             queuePosition: position, memory: memory, policy: req.policy)
        guard reason == "memory" else {
            r.nextStep = "Try again in a minute, or wait longer with `--wait-for-memory 10m`. `fast-ios leases` shows the queue."
            return r
        }
        let advice = await MemoryAdvice.current(policy: req.policy, memory: memory, withApps: true)
        r.usage = advice.usage
        r.simulators = advice.simulators
        r.largestApps = advice.largestApps
        r.nextStep = advice.nextStep
            + (req.memoryWait < 1 ? " Or wait for memory with `--wait-for-memory 5m` (a line about every 30 s while it waits)." : "")
        return r
    }

    enum Decision {
        case use(String, LeaseResult.Source)
        case create(String)
        case reclaim(String)
        case wait(reason: String, detail: String, position: Int)
    }

    /// True when the pool simulator existed before fast-ios (`--allow-existing`).
    static func isAdopted(_ udid: String) -> Bool {
        (try? LeaseStore.withLock { $0.pool[udid]?.adopted }) ?? nil ?? true
    }

    static func prepare(udid: String, source: LeaseResult.Source, req: LeaseRequest, owner: String, ownerPid: Int32?,
                        started: Date, set: String, runtime: String, deviceType: String, log: Log) async throws -> LeaseResult {
        let prepStart = Date()
        do {
            let device = try await Simctl.device(udid)
            let timeout = SimHealth.bootTimeout(memory: .read())
            log(source == .reusedBooted ? "Using \(device.name), already running; making it light for this app…" : "Making \(device.name) light, then starting it (fast-ios replaces it if it hangs for \(LeaseManager.duration(timeout)))…")
            do {
                _ = try await Simctl.$bootTimeout.withValue(timeout) {
                    try await Slimmer.slim(device, profile: req.profile, boot: true, log: log)
                }
            } catch let failure as BootFailure {
                throw BootFailureContext(udid: udid, adopted: isAdopted(udid), failure: failure)
            } catch let e as ShellError where e.command.contains("launchctl") {
                // Booted, but launchd inside it did not answer the override check.
                throw BootFailureContext(udid: udid, adopted: isAdopted(udid),
                                         failure: .notResponding(e.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            let expires = Date().addingTimeInterval(req.ttl)
            try LeaseStore.withLock { state in
                state.leases[udid]?.status = .ready
                state.leases[udid]?.expiresAt = expires
            }
            return LeaseResult(status: "leased", udid: udid, name: device.name, deviceSet: set.isEmpty ? nil : set,
                               runtime: runtime, deviceType: deviceType, profile: req.profile.name, source: source,
                               owner: owner, ownerPid: ownerPid, expiresAt: expires,
                               waitedSeconds: (prepStart.timeIntervalSince(started) * 10).rounded() / 10,
                               prepareSeconds: (Date().timeIntervalSince(prepStart) * 10).rounded() / 10)
        } catch {
            _ = try? LeaseStore.withLock { $0.leases[udid] = nil }
            throw error
        }
    }

    /// Ends a lease. The simulator stays booted for the next lease unless
    /// `shutdown` is set or more than `maxIdle` pool simulators sit idle.
    public static func release(_ udid: String, shutdown: Bool = false, log: Log = { _ in }) async throws -> Bool {
        let had = try LeaseStore.withLock { state -> Bool in
            state.reap()
            let had = state.leases.removeValue(forKey: udid) != nil
            if had { state.pool[udid]?.idleSince = Date() }
            return had
        }
        if shutdown, try LeaseStore.withLock({ $0.pool[udid] != nil }) {
            try LeaseStore.withLock { $0.pool[udid]?.draining = true }
            _ = try? await Simctl.shutdownAndWait(udid)
            try LeaseStore.withLock { $0.pool[udid]?.draining = false }
        }
        await trimIdle(log: log)
        return had
    }

    /// The warm size: `FASTIOS_MAX_IDLE`, else `fast-ios pool --size`, else 1.
    public static var warmSize: Int {
        ProcessInfo.processInfo.environment["FASTIOS_MAX_IDLE"].flatMap(Int.init) ?? PoolConfig.load().size
    }

    /// Shuts down free pool simulators that are not worth their memory
    /// (PoolTrim): all of them while memory is short, any free longer than
    /// the idle limit, and the oldest beyond the warm size. Never one that is
    /// leased or that fast-ios did not create. Returns what it shut down.
    @discardableResult
    public static func trimIdle(policy: AdmissionPolicy = AdmissionPolicy(), memory: MemoryStatus? = nil,
                                log: Log = { _ in }) async -> [PoolTrim.Decision] {
        guard let devices = try? await Simctl.listDevices() else { return [] }
        let booted = Set(devices.filter(\.isBooted).map(\.udid))
        let set = currentSet
        let mem = memory ?? MemoryStatus.read()
        let size = warmSize, limit = PoolTrim.idleLimit
        let toStop: [PoolTrim.Decision] = (try? LeaseStore.withLock { state in
            state.reap()
            let d = PoolTrim.decide(pool: Array(state.pool.values), leased: Set(state.leases.keys), booted: booted, set: set,
                                    memory: mem, policy: policy, warmSize: size, idleLimit: limit)
            for x in d { state.pool[x.udid]?.draining = true }
            return d
        }) ?? []
        let names = Dictionary(devices.map { ($0.udid, $0.name) }, uniquingKeysWith: { a, _ in a })
        for x in toStop {
            let why = switch x.reason {
            case .memory: "memory is short (\(mem.pressure), \(mem.availableMB) MB free)"
            case .idle: "nobody used it for \(Int(limit / 60)) min"
            case .overSize: "more than \(size) were kept warm"
            }
            log("Shutting down free pool simulator \(names[x.udid] ?? x.udid): \(why).")
            _ = try? await Simctl.shutdownAndWait(x.udid)
            _ = try? LeaseStore.withLock { $0.pool[x.udid]?.draining = false }
        }
        return toStop
    }

    public static func list() async throws -> LeaseListing {
        // Listing also stops free pool simulators that are not worth their memory.
        let stopped = await trimIdle()
        let listedDevices = try? await Simctl.listDevices()
        let devices = listedDevices ?? []
        let names = Dictionary(devices.map { ($0.udid, $0.name) }, uniquingKeysWith: { a, _ in a })
        let set = currentSet
        let listed = listedDevices != nil
        let (state, released) = try LeaseStore.withLock { state -> (LeaseState, [Lease]) in
            let r = state.reap()
            if listed {
                for (udid, d) in state.pool where d.deviceSet == set && names[udid] == nil && state.leases[udid] == nil {
                    state.pool[udid] = nil
                }
            }
            return (state, r)
        }
        let now = Date()
        let rows = state.leases.values.sorted { $0.leasedAt < $1.leasedAt }.map {
            LeaseListing.Row(udid: $0.udid, name: names[$0.udid], owner: $0.owner, ownerPid: $0.ownerProcess?.pid,
                             ownerAlive: $0.ownerProcess?.isAlive, status: $0.status.rawValue, profile: $0.profileName,
                             leasedAt: $0.leasedAt, expiresAt: $0.expiresAt,
                             remainingSeconds: max(0, Int($0.expiresAt.timeIntervalSince(now))))
        }
        let memory = MemoryStatus.read()
        let booted = Set(devices.filter(\.isBooted).map(\.udid))
        var listing = LeaseListing(leases: rows, pool: state.pool.values.sorted { $0.createdAt < $1.createdAt },
                                   queue: state.queue, released: released.map(\.udid), memory: memory)
        listing.shutDown = stopped
        listing.poolStatus = PoolTrim.describe(pool: Array(state.pool.values), leased: Set(state.leases.keys), booted: booted,
                                               set: set, memory: memory, policy: AdmissionPolicy(), warmSize: warmSize,
                                               idleLimit: PoolTrim.idleLimit, now: now)
        return listing
    }

    // MARK: - Runtime and device type

    private struct Runtimes: Decodable {
        struct Runtime: Decodable {
            struct DeviceType: Decodable { let identifier: String; let name: String; let productFamily: String? }
            let identifier: String
            let name: String
            let version: String
            let platform: String?
            let isAvailable: Bool
            let supportedDeviceTypes: [DeviceType]?
        }
        let runtimes: [Runtime]
    }

    public static func resolveTarget(runtime: String?, deviceType: String?) async throws -> (String, String) {
        let list = try JSONDecoder().decode(Runtimes.self, from: try await Simctl.simctl("list", "runtimes", "-j").stdout)
        let ios = list.runtimes.filter { $0.isAvailable && ($0.platform ?? "iOS") == "iOS" }
        let rt: Runtimes.Runtime?
        func hasPro(_ r: Runtimes.Runtime) -> Bool {
            (r.supportedDeviceTypes ?? []).contains { $0.productFamily == "iPhone" && $0.name.hasSuffix(" Pro") }
        }
        func newer(_ a: Runtimes.Runtime, _ b: Runtimes.Runtime) -> Bool {
            a.version.compare(b.version, options: .numeric) == .orderedAscending
        }
        if let runtime {
            rt = ios.first { $0.identifier == runtime || $0.name == runtime || $0.version == runtime }
        } else {
            // Newest runtime that offers an iPhone Pro; a runtime with only an
            // unusual device type (a beta's single model) is a poor default.
            rt = ios.filter(hasPro).max(by: newer) ?? ios.max(by: newer)
        }
        guard let rt else { throw SimctlError(message: "No available iOS runtime matches \(runtime ?? "(newest)").") }
        let types = rt.supportedDeviceTypes ?? []
        let dt: Runtimes.Runtime.DeviceType?
        if let deviceType {
            dt = types.first { $0.identifier == deviceType || $0.name == deviceType }
        } else {
            // The highest-numbered iPhone Pro ("iPhone 18 Pro" over "iPhone 11 Pro");
            // simctl's list order is not a promise.
            let byName: (Runtimes.Runtime.DeviceType, Runtimes.Runtime.DeviceType) -> Bool = {
                $0.name.compare($1.name, options: .numeric) == .orderedAscending
            }
            dt = types.filter { $0.productFamily == "iPhone" && $0.name.hasSuffix(" Pro") }.max(by: byName)
                ?? types.filter { $0.productFamily == "iPhone" }.max(by: byName)
        }
        guard let dt else { throw SimctlError(message: "\(rt.name) has no device type \(deviceType ?? "iPhone").") }
        return (rt.identifier, dt.identifier)
    }
}
