import Foundation
import Synchronization

public struct HealOutput: Encodable, Sendable {
    public var schemaVersion = JSONOutput.schemaVersion
    public let udid: String
    public let bundleIdentifier: String
    public let events: [HealEvent]
    public let repaired: Int
}

public struct RepairsOutput: Encodable, Sendable {
    public var schemaVersion = JSONOutput.schemaVersion
    public let repairs: [HealEvent]
    /// bundle id -> labels heal learned and every later profile keeps.
    public let learned: [String: [String]]
}

extension FastIOSCommands {
    public static func heal(simulator: String, app: String, seconds: Int, cooldown: Int?, maxRepairs: Int?,
                            emit: @escaping @Sendable (HealEvent) -> Void = { _ in }) async throws -> HealOutput {
        let device = try await Simctl.resolve(simulator)
        let (bundleID, executable) = try await Healer.appIdentity(app, udid: device.udid)
        var options = HealOptions()
        options.duration = TimeInterval(seconds)
        if let cooldown { options.cooldown = TimeInterval(cooldown) }
        if let maxRepairs { options.maxRepairs = maxRepairs }
        let events = Mutex<[HealEvent]>([])
        try await Healer.run(device: device, bundleID: bundleID, executable: executable, options: options) { e in
            events.withLock { $0.append(e) }
            emit(e)
        }
        let all = events.withLock { $0 }
        return HealOutput(udid: device.udid, bundleIdentifier: bundleID, events: all,
                          repaired: all.filter { $0.event == "repaired" }.count)
    }

    public static func repairs(udid: String?, bundleID: String?, limit: Int?) -> RepairsOutput {
        RepairsOutput(repairs: HealStore.repairs(udid: udid, bundleID: bundleID, limit: limit ?? 100),
                      learned: HealStore.learned().mapValues { $0.keys.sorted() })
    }
}

extension MCPTools {
    static let healEvent = Schema.object([
        "schemaVersion": Schema.integer(),
        "event": Schema.string("healing, repaired, repair-failed, ignored, cap-reached or stopped"),
        "time": Schema.string(), "udid": Schema.string(), "bundleIdentifier": Schema.string(),
        "label": Schema.string(), "machService": Schema.string(), "process": Schema.string(),
        "why": Schema.string(), "evidence": Schema.string(), "repairMs": Schema.integer(),
        "savedToProfile": Schema.boolean(),
    ], required: ["schemaVersion", "event", "time", "udid", "bundleIdentifier"])

    static let heal = MCPTool(
        name: "heal", title: "Turn on services the app turns out to need",
        description: "For `seconds`, follow a booted simulator's log. When the app fails to reach a service fast-ios turned off, turn that service on without a reboot (1 to 3 s) and save it to the app's profile, so later slims keep it. Run it while the app or its tests run, then retry the failed step. Guards: one attempt per service per cool-down, at most maxRepairs services, never touches services fast-ios never turns off. Proved for photos and contacts. Push is not detected (SpringBoard makes that call); an app with aps-environment keeps push anyway. Other services may fail without a log line it recognises.",
        inputSchema: Schema.object([
            "simulator": simulatorArg,
            "app": Schema.string("The app: its bundle id (installed on the simulator) or a .app path."),
            "seconds": Schema.integer("How long to watch, 1 to 1800."),
            "cooldown": Schema.integer("Seconds before the same service is tried again (default 30)."),
            "maxRepairs": Schema.integer("Most services to turn on in this call (default 10)."),
            "deviceSet": deviceSetArg,
        ], required: ["simulator", "app", "seconds"]),
        outputSchema: Schema.object([
            "schemaVersion": Schema.integer(), "udid": Schema.string(), "bundleIdentifier": Schema.string(),
            "events": Schema.array(healEvent), "repaired": Schema.integer(),
        ], required: ["schemaVersion", "udid", "bundleIdentifier", "events", "repaired"]),
        annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        positional: ["simulator"]
    ) { args in
        let seconds = args.int("seconds") ?? 0
        guard (1...1800).contains(seconds) else { throw InvalidArguments("seconds must be 1 to 1800.") }
        return try await FastIOSCommands.heal(simulator: try args.string("simulator"), app: try args.string("app"),
                                              seconds: seconds, cooldown: args.int("cooldown"), maxRepairs: args.int("maxRepairs"))
    }

    static let repairs = MCPTool(
        name: "repairs", title: "List services heal turned on",
        description: "Every service heal turned on (or failed to), newest last: which service, the app, why (the log line), and how long the repair took; plus, per app, the services heal learned and every later profile keeps. Read-only.",
        inputSchema: Schema.object([
            "udid": Schema.string("Only this simulator."),
            "bundleId": Schema.string("Only this app."),
            "limit": Schema.integer("Most events to return (default 100)."),
        ]),
        outputSchema: Schema.object([
            "schemaVersion": Schema.integer(), "repairs": Schema.array(healEvent), "learned": Schema.map(strings),
        ], required: ["schemaVersion", "repairs", "learned"]),
        annotations: readOnly
    ) { args in FastIOSCommands.repairs(udid: args.optionalString("udid"), bundleID: args.optionalString("bundleId"), limit: args.int("limit")) }
}
