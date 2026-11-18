import Foundation
import Testing
@testable import FastIOSCore

@Suite("Colour: when, and never in the way")
struct ColorTests {
    let tty = ["TERM": "xterm-256color"]

    @Test("Colour only on a terminal, never in --json or with --no-color")
    func terminalOnly() {
        #expect(TerminalColor.depth(isTerminal: true, environment: tty, json: false, noColorFlag: false) == .palette256)
        #expect(TerminalColor.depth(isTerminal: false, environment: tty, json: false, noColorFlag: false) == .none)
        #expect(TerminalColor.depth(isTerminal: true, environment: tty, json: true, noColorFlag: false) == .none)
        #expect(TerminalColor.depth(isTerminal: true, environment: tty, json: false, noColorFlag: true) == .none)
        #expect(TerminalColor.depth(isTerminal: true, environment: ["TERM": "xterm"], json: false, noColorFlag: false) == .basic)
    }

    @Test("NO_COLOR (any value), CLICOLOR=0 and TERM=dumb turn colour off, even when forced")
    func offSwitches() {
        for env in [["NO_COLOR": ""], ["NO_COLOR": "1"], ["CLICOLOR": "0"], ["TERM": "dumb"]] {
            let forced = env.merging(["FORCE_COLOR": "1"]) { a, _ in a }
            #expect(TerminalColor.depth(isTerminal: true, environment: env, json: false, noColorFlag: false) == .none, "\(env)")
            #expect(TerminalColor.depth(isTerminal: false, environment: forced, json: false, noColorFlag: false) == .none, "\(forced)")
        }
    }

    @Test("FORCE_COLOR or CLICOLOR_FORCE=1 colour piped output; FORCE_COLOR=0 does not")
    func forcing() {
        #expect(TerminalColor.depth(isTerminal: false, environment: ["FORCE_COLOR": "1"], json: false, noColorFlag: false) == .basic)
        #expect(TerminalColor.depth(isTerminal: false, environment: ["CLICOLOR_FORCE": "1"], json: false, noColorFlag: false) == .basic)
        #expect(TerminalColor.depth(isTerminal: false, environment: ["FORCE_COLOR": "0"], json: false, noColorFlag: false) == .none)
        #expect(TerminalColor.depth(isTerminal: false, environment: ["FORCE_COLOR": "1"], json: true, noColorFlag: false) == .none)
    }

    @Test("No style uses bright white or black, so it reads on light and dark backgrounds")
    func safePalette() {
        for depth in [TerminalColor.Depth.basic, .palette256] {
            for role in TerminalColor.Role.allCases {
                let sgr = TerminalColor.sgr(role, depth)
                for banned in ["30", "37", "97", "90", "38;5;15", "38;5;16", "38;5;231", "38;5;0", "38;5;7"] {
                    #expect(!sgr.split(separator: ";").map(String.init).elementsEqual(banned.split(separator: ";").map(String.init)),
                            "\(role) at \(depth) is \(sgr)")
                }
            }
        }
        #expect(TerminalColor.paint("light", [.good], .none) == "light")
    }
}

/// The same rules on the built program.
@Suite("Colour in the fast-ios program", .serialized)
struct ColorBinaryTests {
    static let esc: UInt8 = 0x1B

    static func run(_ args: [String], env: [String: String] = [:]) throws -> (out: Data, err: Data, status: Int32) {
        guard let bin = CLIBinaryTests.binary else { throw CocoaError(.fileNoSuchFile) }
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        for k in ["NO_COLOR", "FORCE_COLOR", "CLICOLOR", "CLICOLOR_FORCE", "FASTIOS_DEVICE_SET"] { e[k] = nil }
        e["TERM"] = "xterm-256color"
        e["FASTIOS_STATE_DIR"] = TestEnv.temp().path
        e["FASTIOS_AGENT_LABEL"] = "dev.fast-ios.colour-test"
        for (k, v) in env { e[k] = v }
        p.environment = e
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let r = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (o, r, p.terminationStatus)
    }

    /// Escape codes removed. Backticks are set aside too: in colour, a
    /// `command` is shown in the accent colour instead of between backticks.
    static func strip(_ d: Data) -> String {
        String(decoding: d, as: UTF8.self).replacing(#/\x1B\[[0-9;]*m/#, with: "").replacing("`", with: "")
    }
    static func words(_ d: Data) -> String { String(decoding: d, as: UTF8.self).replacing("`", with: "") }

    @Test("Piped output is free of escape codes; forced colour adds them and changes no word")
    func pipedIsPlain() throws {
        guard CLIBinaryTests.binary != nil else { Issue.record("fast-ios was not built next to the tests"); return }
        let set = TestEnv.temp().path
        for args in [["help"], ["on", "--help"], ["status", "--set", set], ["--version"]] {
            let plain = try Self.run(args)
            #expect(!plain.out.contains(Self.esc) && !plain.err.contains(Self.esc), "\(args) piped")
            let forced = try Self.run(args, env: ["FORCE_COLOR": "1"])
            if args == ["help"] || args == ["on", "--help"] { #expect(forced.out.contains(Self.esc), "\(args) forced") }
            #expect(Self.strip(forced.out) == Self.words(plain.out), "\(args): colour changed the words")
        }
    }

    @Test("NO_COLOR, CLICOLOR=0, TERM=dumb, --no-color and --json win over FORCE_COLOR")
    func offWins() throws {
        guard CLIBinaryTests.binary != nil else { Issue.record("fast-ios was not built next to the tests"); return }
        let cases: [([String], [String: String])] = [
            (["help"], ["NO_COLOR": ""]), (["help"], ["CLICOLOR": "0"]), (["help"], ["TERM": "dumb"]),
            (["help", "--no-color"], [:]), (["status", "--json", "--set", TestEnv.temp().path], [:]),
        ]
        for (args, env) in cases {
            let r = try Self.run(args, env: env.merging(["FORCE_COLOR": "1"]) { a, _ in a })
            #expect(!r.out.contains(Self.esc) && !r.err.contains(Self.esc), "\(args) \(env)")
        }
    }

    @Test("An error keeps its words in colour and in plain text, and exits the same")
    func errors() throws {
        guard CLIBinaryTests.binary != nil else { Issue.record("fast-ios was not built next to the tests"); return }
        let plain = try Self.run(["on", "--nope"])
        let forced = try Self.run(["on", "--nope"], env: ["FORCE_COLOR": "1"])
        #expect(plain.status == 64 && forced.status == 64)
        #expect(!plain.err.contains(Self.esc) && forced.err.contains(Self.esc))
        #expect(Self.strip(forced.err) == Self.words(plain.err))
        #expect(String(decoding: plain.err, as: UTF8.self).hasPrefix("fast-ios: "))
    }
}
