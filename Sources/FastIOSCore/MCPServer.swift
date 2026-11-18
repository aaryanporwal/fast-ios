import Foundation

/// `fast-ios mcp`: a Model Context Protocol server over stdio. JSON-RPC 2.0,
/// one message per line. Implements initialize, ping, tools/list and
/// tools/call; notifications get no reply. Requests run one at a time, in
/// order. stdout carries only protocol messages; nothing else may print.
public enum MCPServer {
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverVersion = "0.2.0"

    static let instructions = """
    fast-ios makes iOS simulators lighter by turning off the simulator services an app does not need \
    (about 2.8 GB to 0.8 GB per simulator). Typical flow: status to pick a simulator you created, \
    profile to preview, slim with the built app, then build and test as usual. If a feature stops \
    working on a slim simulator, slim again with keep=[label] (labels are in catalog), or off to restore stock. \
    Never slim, reboot or delete a simulator you did not create: someone else may be using it.
    """

    public static func run(tools: [MCPTool] = MCPTools.all) async throws {
        for try await line in FileHandle.standardInput.bytes.lines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = await handle(line: line, tools: tools) {
                write(reply)
            }
        }
    }

    /// Handles one line. Returns the reply, or nil for a notification.
    public static func handle(line: String, tools: [MCPTool] = MCPTools.all) async -> JSONValue? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              case .object(let m) = message else {
            return errorReply(id: .null, code: -32700, message: "Parse error: not a JSON object.")
        }
        guard let method = m["method"]?.string else {
            // A response from the client (we send no requests) or garbage.
            return m["id"] == nil ? nil : errorReply(id: m["id"] ?? .null, code: -32600, message: "Invalid request: no method.")
        }
        guard let id = m["id"] else { return nil }  // notification
        let params = m["params"]?.object ?? [:]

        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? ""
            let version = supportedVersions.contains(asked) ? asked : supportedVersions[0]
            return result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "fast-ios", "title": "fast-ios", "version": .string(serverVersion)],
                "instructions": .string(instructions),
            ])
        case "ping":
            return result(id: id, [:])
        case "tools/list":
            return result(id: id, ["tools": .array(tools.map(\.listing))])
        case "tools/call":
            guard let name = params["name"]?.string else {
                return errorReply(id: id, code: -32602, message: "tools/call needs params.name.")
            }
            guard let tool = tools.first(where: { $0.name == name }) else {
                return errorReply(id: id, code: -32602, message: "Unknown tool: \(name).")
            }
            return result(id: id, await callResult(tool, arguments: params["arguments"]?.object ?? [:]))
        default:
            return errorReply(id: id, code: -32601, message: "Method not found: \(method).")
        }
    }

    /// A CallToolResult. Tool failures are results with isError, not JSON-RPC errors.
    static func callResult(_ tool: MCPTool, arguments: [String: JSONValue]) async -> JSONValue {
        do {
            let output = try await tool.call(arguments)
            return ["content": [["type": "text", "text": .string(try JSONOutput.encode(output, pretty: false))]],
                    "structuredContent": output, "isError": false]
        } catch {
            let text = (try? JSONOutput.encode(JSONOutput.error(error), pretty: false)) ?? error.localizedDescription
            return ["content": [["type": "text", "text": .string(text)]], "isError": true]
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func errorReply(id: JSONValue, code: Int64, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }

    static func write(_ message: JSONValue) {
        guard let text = try? JSONOutput.encode(message, pretty: false) else { return }
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}
