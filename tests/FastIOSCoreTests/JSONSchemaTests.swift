import Foundation
import Testing
@testable import FastIOSCore

/// The `--json` output and the MCP tools are a public interface: agents parse
/// these field names. This suite fails when a tool, an argument or a required
/// output field is renamed or removed. Adding one means updating `contract`
/// (and, for a rename or removal, bumping JSONOutput.schemaVersion).
@Suite("JSON output schemas stay stable")
struct JSONSchemaTests {
    static let contract: [String: (input: [String], output: [String])] = [
        "status": (input: ["deviceSet"], output: ["deviceSet", "schemaVersion", "simulators"]),
        "profile": (input: ["app", "keep"], output: ["app", "bundleIdentifier", "catalogCount", "matchedRules", "neverDisabled", "profile", "schemaVersion"]),
        "slim": (input: ["app", "boot", "deviceSet", "full", "keep", "simulator", "strict"], output: ["booted", "disabled", "log", "notHonoured", "profile", "reenabled", "schemaVersion", "simulator", "verified"]),
        "off": (input: ["boot", "deviceSet", "simulator"], output: ["alreadyStock", "booted", "log", "reenabled", "schemaVersion", "simulator"]),
        "measure": (input: ["deviceSet", "simulator"], output: ["processCount", "processes", "schemaVersion", "simulator", "totalBytes"]),
        "catalog": (input: [], output: ["categories", "neverDisabled", "schemaVersion", "slimmableCount"]),
        "lease": (input: ["allowExisting", "app", "deviceSet", "deviceType", "full", "keep", "maxPressure", "needMb", "owner", "pid", "reserveMb", "runtime", "timeout", "ttl"], output: ["schemaVersion", "status", "udid", "waitedSeconds"]),
        "release": (input: ["deviceSet", "shutdown", "udid"], output: ["schemaVersion", "status", "udid"]),
        "leases": (input: ["deviceSet"], output: ["deviceSet", "leases", "memory", "pool", "queue", "released", "schemaVersion"]),
        "heal": (input: ["app", "cooldown", "deviceSet", "maxRepairs", "seconds", "simulator"], output: ["bundleIdentifier", "events", "repaired", "schemaVersion", "udid"]),
        "repairs": (input: ["bundleId", "limit", "udid"], output: ["learned", "repairs", "schemaVersion"]),
        "shot": (input: ["app", "build", "buildTimeout", "builtApp", "configuration", "deviceSet", "grant", "maxWidth", "noSession", "noTree", "out", "scale", "timeout", "udid", "url", "variant", "wait"], output: ["appPath", "bundleId", "changedPercent", "granted", "installed", "log", "openPromptAccepted", "pixelsPerPoint", "schemaVersion", "screenStability", "screenStable", "screenshot", "screenshotBytes", "screenshotHeight", "screenshotWidth", "simulator", "simulatorSource", "timings", "totalMs", "tree", "treeElements", "treeNote", "treeSession", "treeStatus", "url", "urlNote", "waitText", "waitTextFound"]),
        "run": (input: ["app", "build", "buildTimeout", "builtApp", "configuration", "deviceSet", "deviceType", "folder", "grant", "keep", "maxPressure", "noLaunch", "runtime", "simulator", "timeout", "ttl", "url", "variant"], output: ["app", "appSource", "bundleIdentifier", "granted", "launched", "leaseExpiresAt", "log", "name", "pid", "profile", "schemaVersion", "seconds", "simulatorSource", "udid", "url"]),
        "apps": (input: ["action", "buildSeconds", "configuration", "project", "target", "variant"], output: ["action", "apps", "folder", "maxBytes", "message", "schemaVersion", "totalBytes", "why"]),
        "pool": (input: ["app", "deviceSet", "deviceType", "full", "idle", "maxPressure", "runtime", "size", "timeout"], output: ["booted", "free", "log", "memory", "schemaVersion", "shortBecause", "size"]),
        "doctor": (input: [], output: ["checks", "ok", "schemaVersion"]),
    ]

    static func keys(_ v: JSONValue?, _ key: String) -> [String] {
        switch v?[key] {
        case .object(let o)?: o.keys.sorted()
        case .array(let a)?: a.compactMap(\.string).sorted()
        default: []
        }
    }

    @Test("schemaVersion is 1")
    func version() { #expect(JSONOutput.schemaVersion == 1) }

    @Test("Every tool, argument and required output field matches the published contract")
    func contractIsStable() {
        #expect(Set(MCPTools.all.map(\.name)) == Set(Self.contract.keys))
        #expect(MCPTools.all.count == Set(MCPTools.all.map(\.name)).count, "tool names are unique")
        for tool in MCPTools.all {
            guard let expected = Self.contract[tool.name] else { continue }
            #expect(Self.keys(tool.inputSchema, "properties") == expected.input, "\(tool.name) input")
            #expect(Self.keys(tool.outputSchema, "required") == expected.output, "\(tool.name) output")
        }
    }

    @Test("Each output schema requires schemaVersion and only names fields it defines")
    func schemasAreWellFormed() {
        for tool in MCPTools.all {
            let props = Set(Self.keys(tool.outputSchema, "properties"))
            let required = Set(Self.keys(tool.outputSchema, "required"))
            #expect(required.contains("schemaVersion"), "\(tool.name)")
            #expect(required.isSubset(of: props), "\(tool.name) requires undefined fields: \(required.subtracting(props))")
            #expect(tool.outputSchema["type"]?.string == "object")
            #expect(tool.inputSchema["additionalProperties"] == .bool(false), "\(tool.name) rejects unknown arguments")
        }
    }

    /// Runs a tool that needs no simulator and checks its real output against its schema.
    static func checkOutput(_ name: String, _ args: [String: JSONValue]) async throws {
        let tool = try #require(MCPTools.named(name))
        let out = try await tool.call(args)
        try SchemaCheck.validate(out, against: tool.outputSchema, path: name)
        let produced = Set(out.object?.keys.map { $0 } ?? [])
        #expect(produced.isSuperset(of: Self.keys(tool.outputSchema, "required")), "\(name) leaves out a required field")
        #expect(produced.isSubset(of: Self.keys(tool.outputSchema, "properties")), "\(name) emits an undeclared field")
    }

    @Test("catalog, profile and repairs output validates against its own schema")
    func realOutputsMatchSchemas() async throws {
        TestEnv.ready()
        try await Self.checkOutput("catalog", [:])
        try await Self.checkOutput("profile", ["app": .string(TestEnv.fixture("Sample.app").path)])
        try await Self.checkOutput("repairs", [:])
    }

    @Test("A shot result validates against the shot schema, with nulls present")
    func shotResultMatchesSchema() throws {
        var result = Shot.Result()
        result.simulator = SimulatorRef(TestEnv.device())
        result.timings = [Shot.Timing(step: "launch", ms: 5)]
        let value = try JSONOutput.value(result)
        let tool = try #require(MCPTools.named("shot"))
        try SchemaCheck.validate(value, against: tool.outputSchema, path: "shot")
        #expect(value["tree"] == .null, "absent optionals encode as null, not as a missing key")
    }

    @Test("Errors have a stable shape and codes")
    func errorShape() {
        let e = JSONOutput.error(SimctlError(message: "No simulator matches \"x\"."))
        #expect(e["schemaVersion"] == .int(1))
        #expect(e["error"]?["code"] == .string("simulator"))
        #expect(e["error"]?["message"] == .string("No simulator matches \"x\"."))
        #expect(JSONOutput.classify(UsageError("u")).code == "usage")
        #expect(JSONOutput.classify(InvalidArguments("i")).code == "invalid_arguments")
        #expect(JSONOutput.classify(InspectError(message: "a")).code == "app")
    }

    @Test("Arguments of the wrong type or unknown names are rejected before anything runs")
    func argumentValidation() async {
        let shot = MCPTools.named("shot")!
        await #expect(throws: InvalidArguments.self) { _ = try await shot.call(["app": "/x.app", "wait": 5]) }
        await #expect(throws: InvalidArguments.self) { _ = try await shot.call(["app": "/x.app", "bogus": true]) }
        await #expect(throws: InvalidArguments.self) { _ = try await shot.call([:]) }
    }

    @Test("CLI words map onto tool arguments")
    func cliMapping() throws {
        let shot = MCPTools.named("shot")!
        let args = try shot.cliArguments(["--app", "A.app", "--no-tree", "--timeout", "7", "--json"])
        #expect(args == ["app": "A.app", "noTree": true, "timeout": .int(7)])
        #expect(throws: UsageError.self) { _ = try shot.cliArguments(["--nope"]) }
    }
}
