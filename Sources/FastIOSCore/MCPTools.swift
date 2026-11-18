import Foundation

/// One fast-ios command as an MCP tool. The same entry also gives the CLI
/// command its `--json` output: `fast-ios <name> <positional…> --flag value
/// --json` is turned into the tool's arguments by the input schema and runs
/// the same handler.
///
/// To add a command: write `static let <name> = MCPTool(...)` in a new file
/// `MCPTools+<Feature>.swift` and add one line to `MCPTools.all`.
public struct MCPTool: Sendable {
    public let name: String
    public let title: String
    public let description: String
    /// JSON Schema (an object schema) for the arguments.
    public let inputSchema: JSONValue
    /// JSON Schema for `structuredContent`, the same object `--json` prints.
    public let outputSchema: JSONValue
    /// MCP tool annotations: readOnlyHint, destructiveHint, idempotentHint, openWorldHint.
    public let annotations: JSONValue
    /// CLI positional arguments, in order, mapped to these argument names.
    public let positional: [String]
    let handler: @Sendable (ToolArguments) async throws -> JSONValue

    public init<Output: Encodable & Sendable>(
        name: String, title: String, description: String,
        inputSchema: JSONValue, outputSchema: JSONValue, annotations: JSONValue,
        positional: [String] = [],
        run: @escaping @Sendable (ToolArguments) async throws -> Output
    ) {
        self.name = name; self.title = title; self.description = description
        self.inputSchema = inputSchema; self.outputSchema = outputSchema; self.annotations = annotations
        self.positional = positional
        self.handler = { try JSONOutput.value(try await run($0)) }
    }

    /// Validates `arguments` against the input schema, applies `deviceSet` for
    /// the length of the call, and runs the handler.
    public func call(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        try SchemaCheck.validate(.object(arguments), against: inputSchema, path: "arguments")
        let args = ToolArguments(arguments)
        guard let set = args.optionalString("deviceSet") else { return try await handler(args) }
        let previous = ProcessInfo.processInfo.environment["FASTIOS_DEVICE_SET"]
        try Simctl.useDeviceSet(set)
        defer {
            if let previous { setenv("FASTIOS_DEVICE_SET", previous, 1) } else { unsetenv("FASTIOS_DEVICE_SET") }
        }
        return try await handler(args)
    }

    /// Runs the tool from CLI words (everything after the command name).
    public func callFromCLI(_ words: [String]) async throws -> JSONValue {
        let args = try cliArguments(words)
        // Say what is missing in CLI words, not as `arguments.udid`.
        for key in inputSchema["required"]?.array?.compactMap(\.string) ?? [] where args[key] == nil {
            let what = positional.contains(key) ? "<\(key)>" : "--\(Self.kebab(key)) <\(key)>"
            throw InvalidArguments("`fast-ios \(name)` needs \(what). Nothing was changed. See `fast-ios \(name) --help`.")
        }
        return try await call(args)
    }

    static func kebab(_ camel: String) -> String {
        camel.reduce(into: "") { s, c in if c.isUppercase { s += "-" + c.lowercased() } else { s.append(c) } }
    }

    /// `--app X --keep a --keep b --boot sim` -> {"app": "X", "keep": ["a","b"], "boot": true, "simulator": "sim"}.
    /// `--some-flag` maps to `someFlag`. `--json` is ignored.
    public func cliArguments(_ words: [String]) throws -> [String: JSONValue] {
        let props = inputSchema["properties"]?.object ?? [:]
        var out: [String: JSONValue] = [:]
        var positionals: [String] = []
        var i = 0
        while i < words.count {
            let w = words[i]; i += 1
            guard w.hasPrefix("--") else { positionals.append(w); continue }
            if w == "--json" { continue }
            let key = Self.camelCase(String(w.dropFirst(2)))
            guard let prop = props[key] else { throw UsageError("\(name) has no option \(w).") }
            switch prop["type"]?.string {
            case "boolean":
                out[key] = true
            case "array":
                guard i < words.count else { throw UsageError("\(w) needs a value.") }
                out[key] = .array((out[key]?.array ?? []) + [.string(words[i])]); i += 1
            case "integer":
                guard i < words.count, let n = Int64(words[i]) else { throw UsageError("\(w) needs a whole number.") }
                out[key] = .int(n); i += 1
            case "number":
                guard i < words.count, let n = Double(words[i]) else { throw UsageError("\(w) needs a number.") }
                out[key] = .double(n); i += 1
            default:
                guard i < words.count else { throw UsageError("\(w) needs a value.") }
                out[key] = .string(words[i]); i += 1
            }
        }
        guard positionals.count <= positional.count else {
            throw UsageError("\(name) takes \(positional.isEmpty ? "no" : "at most \(positional.count)") positional argument(s); got \(positionals.joined(separator: " ")).")
        }
        for (key, value) in zip(positional, positionals) { out[key] = .string(value) }
        return out
    }

    static func camelCase(_ kebab: String) -> String {
        let parts = kebab.split(separator: "-")
        return (parts.first.map(String.init) ?? "") + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// The `tools/list` entry.
    public var listing: JSONValue {
        ["name": .string(name), "title": .string(title), "description": .string(description),
         "inputSchema": inputSchema, "outputSchema": outputSchema, "annotations": annotations]
    }
}

public enum MCPTools {
    /// Every tool, in `tools/list` order. One entry per command.
    public static let all: [MCPTool] = [
        status, profile, slim, off, measure, catalog,
        lease, release, leases,
        heal, repairs,
        shot,
        run,
        apps,
        pool,
        doctor,
    ]

    public static func named(_ name: String) -> MCPTool? { all.first { $0.name == name } }
}

/// Typed access to validated tool arguments.
public struct ToolArguments: Sendable {
    public let raw: [String: JSONValue]
    public init(_ raw: [String: JSONValue]) { self.raw = raw }

    public func string(_ key: String) throws -> String {
        guard let s = raw[key]?.string else { throw InvalidArguments("\(key) is required.") }
        return s
    }
    public func optionalString(_ key: String) -> String? { raw[key]?.string }
    public func bool(_ key: String) -> Bool { raw[key]?.bool ?? false }
    /// A number argument, whether JSON sent it as an integer or a decimal.
    public func number(_ key: String) -> Double? {
        switch raw[key] {
        case .int(let i)?: Double(i)
        case .double(let d)?: d
        default: nil
        }
    }
    public func strings(_ key: String) -> [String] { raw[key]?.array?.compactMap(\.string) ?? [] }
}

/// Short constructors for the JSON Schema subset the tools use.
public enum Schema {
    public static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties),
         "required": .array(required.map { .string($0) }), "additionalProperties": false]
    }
    public static func string(_ description: String? = nil) -> JSONValue { typed("string", description) }
    public static func boolean(_ description: String? = nil) -> JSONValue { typed("boolean", description) }
    public static func integer(_ description: String? = nil) -> JSONValue { typed("integer", description) }
    public static func number(_ description: String? = nil) -> JSONValue { typed("number", description) }
    public static func array(_ items: JSONValue, _ description: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "array", "items": items]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }
    /// `type` or null.
    public static func nullable(_ type: String, _ description: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": [.string(type), "null"]]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }
    /// An object whose values all match `values` (a map).
    public static func map(_ values: JSONValue) -> JSONValue {
        ["type": "object", "additionalProperties": values]
    }
    static func typed(_ type: String, _ description: String?) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string(type)]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }
}

/// Validates a value against the JSON Schema subset above: type (string or
/// list), properties, required, additionalProperties (bool or schema), items.
enum SchemaCheck {
    static func validate(_ value: JSONValue, against schema: JSONValue, path: String) throws {
        if let types = schema["type"] {
            let allowed = types.array?.compactMap(\.string) ?? [types.string].compactMap { $0 }
            guard allowed.contains(where: { matches(value, $0) }) else {
                throw InvalidArguments("\(path) must be \(allowed.joined(separator: " or ")).")
            }
        }
        if case .object(let o) = value {
            let props = schema["properties"]?.object ?? [:]
            for key in schema["required"]?.array?.compactMap(\.string) ?? [] where o[key] == nil {
                throw InvalidArguments("\(path).\(key) is required.")
            }
            for (key, v) in o {
                if let p = props[key] { try validate(v, against: p, path: "\(path).\(key)"); continue }
                switch schema["additionalProperties"] {
                case .bool(false)?: throw InvalidArguments("\(path).\(key) is not a known field.")
                case let extra? where extra.object != nil: try validate(v, against: extra, path: "\(path).\(key)")
                default: break
                }
            }
        }
        if case .array(let a) = value, let items = schema["items"] {
            for (i, v) in a.enumerated() { try validate(v, against: items, path: "\(path)[\(i)]") }
        }
    }

    static func matches(_ value: JSONValue, _ type: String) -> Bool {
        switch (type, value) {
        case ("string", .string), ("boolean", .bool), ("integer", .int), ("number", .int), ("number", .double),
             ("array", .array), ("object", .object), ("null", .null): true
        default: false
        }
    }
}
