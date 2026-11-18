import Foundation
import Testing
@testable import FastIOSCore

/// Every command the CLI dispatches must have per-command help. The commands
/// come from main.swift's `case "…"` and `command == "…"` lines plus the MCP
/// tools, so a new command fails this test until it has a CLISpec entry.
@Suite("Every command has --help")
struct CLIHelpTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// The built binary: beside the test resources, or in the build folder
    /// (the layout differs between SwiftPM's build systems).
    static var binary: URL {
        let candidates = [
            Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("fast-ios"),
            repo.appendingPathComponent(".build/out/Products/Debug/fast-ios"),
            repo.appendingPathComponent(".build/debug/fast-ios"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? candidates[0]
    }

    /// Command names main.swift dispatches on, plus every MCP tool.
    static func dispatched() throws -> Set<String> {
        let main = try String(contentsOf: repo.appendingPathComponent("Sources/fast-ios/main.swift"), encoding: .utf8)
        var names = Set(MCPTools.all.map(\.name))
        for line in main.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("case \"") {
                let head = text.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                for m in head.matches(of: #/"([a-z_][a-z0-9_-]*)"/#) { names.insert(String(m.1)) }
            }
            for m in text.matches(of: #/command == "([a-z][a-z0-9-]*)"/#) { names.insert(String(m.1)) }
        }
        // Not user commands: help itself, and the background helper's entry point.
        return names.subtracting(["help", "_agent"])
    }

    static func run(_ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        let state = TestEnv.ready()
        // The first run in a state folder prints a welcome message first.
        FileManager.default.createFile(atPath: state.appendingPathComponent("welcomed").path, contents: nil)
        env["FASTIOS_STATE_DIR"] = state.path
        env["FASTIOS_DEVICE_SET"] = nil
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test("Every dispatched command is in the help table, and `--help` prints it")
    func everyCommandHasHelp() throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "build fast-ios first: \(Self.binary.path)")
        let commands = try Self.dispatched()
        #expect(commands.count >= 15, "parsed \(commands.count) commands from main.swift; the parser is broken")

        // Checked without running a command: one with no help entry could
        // treat --help as an unknown flag and do its real work.
        let listing = try Self.run(["help", "--json"])
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(listing.output.utf8))
        let withHelp = Set((json["helpCommands"]?.array ?? []).compactMap(\.string))
        let missing = commands.subtracting(withHelp)
        #expect(missing.isEmpty, "no per-command help (add a CLISpec entry): \(missing.sorted())")

        for command in commands.intersection(withHelp).sorted() {
            let r = try Self.run([command, "--help"])
            #expect(r.status == 0, "`fast-ios \(command) --help` exited \(r.status): \(r.output.prefix(200))")
            #expect(!r.output.contains("unknown option") && !r.output.contains("has no option"),
                    "`fast-ios \(command) --help`: \(r.output.prefix(200))")
            #expect(r.output.hasPrefix("fast-ios \(command)"), "`fast-ios \(command) --help` does not start with its synopsis")
        }
    }
}
