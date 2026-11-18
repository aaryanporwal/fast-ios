import Foundation
import Testing
@testable import FastIOSCore

/// Runs the built `fast-ios` program (swift test builds it next to the test
/// bundle). Every run gets its own state folder and a test LaunchAgent label,
/// so nothing here can touch real state or the real helper.
@Suite("The fast-ios program", .serialized)
struct CLIBinaryTests {
    static let testLabel = "dev.fast-ios.cli-test"

    static var binary: URL? {
        var dir = Bundle.module.bundleURL.deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent("fast-ios")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    struct Run { let status: Int32; let out: String; let err: String; let seconds: Double }

    static func run(_ args: [String], executable: String? = nil, path: String? = nil, cwd: URL? = nil,
                    stateDir: URL) throws -> Run {
        let p = Process()
        if let executable {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [executable] + args
        } else {
            guard let built = Self.binary else { throw CocoaError(.fileNoSuchFile) }
            p.executableURL = built
            p.arguments = args
        }
        var env = ProcessInfo.processInfo.environment
        env["FASTIOS_STATE_DIR"] = stateDir.path
        env["FASTIOS_AGENT_LABEL"] = testLabel
        env["FASTIOS_DEVICE_SET"] = nil
        if let path { env["PATH"] = path }
        p.environment = env
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        let start = Date()
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Run(status: p.terminationStatus, out: String(decoding: o, as: UTF8.self),
                   err: String(decoding: e, as: UTF8.self), seconds: Date().timeIntervalSince(start))
    }

    static var testPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(testLabel).plist")
    }

    /// Every command `fast-ios help` lists.
    static func commands() throws -> [String] {
        let help = try run(["help"], stateDir: TestEnv.temp())
        return help.out.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("  "), let word = line.split(separator: " ").first, word.first?.isLetter == true else { return nil }
            return String(word)
        }
    }

    @Test("Every command refuses an unknown option with exit 64 before anything runs")
    func unknownOptionChangesNothing() throws {
        guard Self.binary != nil else { Issue.record("fast-ios was not built next to the tests"); return }
        let commands = try Self.commands()
        #expect(commands.count >= 20)
        #expect(["on", "off", "slim", "run", "pool", "template", "release"].allSatisfy(commands.contains))
        for command in commands {
            let state = TestEnv.temp().appendingPathComponent("state")       // must stay absent
            let set = TestEnv.temp().appendingPathComponent("never-made")    // must stay absent
            for bad in ["--definitely-not-an-option", "--dry-run=1"] where !(bad == "--dry-run=1" && command == "version") {
                let r = try Self.run([command, "--set", set.path, bad], stateDir: state)
                #expect(r.status == 64, "\(command) \(bad): exit \(r.status), \(r.err)")
                #expect(r.err.contains("Nothing was changed"), "\(command) \(bad): \(r.err)")
                #expect(r.seconds < 5, "\(command) \(bad) took \(r.seconds) s")
                #expect(!FileManager.default.fileExists(atPath: state.path), "\(command) \(bad) wrote state")
                #expect(!FileManager.default.fileExists(atPath: set.path), "\(command) \(bad) created the --set folder")
                #expect(!FileManager.default.fileExists(atPath: Self.testPlist.path), "\(command) \(bad) installed a helper")
            }
        }
        // JSON mode refuses the same way, as JSON.
        let r = try Self.run(["on", "--json", "--definitely-not-an-option"], stateDir: TestEnv.temp().appendingPathComponent("s"))
        #expect(r.status == 64 && r.out.contains("\"code\" : \"usage\""))
    }

    @Test("Run by bare name through PATH from another folder, on finds its own program")
    func runFromPath() throws {
        guard let binary = Self.binary else { Issue.record("fast-ios was not built next to the tests"); return }
        let elsewhere = TestEnv.temp()
        let set = TestEnv.temp().path
        let r = try Self.run(["on", "--dry-run", "--set", set], executable: "fast-ios",
                             path: binary.deletingLastPathComponent().path + ":/usr/bin:/bin", cwd: elsewhere,
                             stateDir: TestEnv.temp().appendingPathComponent("state"))
        #expect(r.status == 0, "\(r.out)\(r.err)")
        #expect(r.out.contains("Dry run: nothing was changed"))
        #expect(!r.out.contains("was not found"))
        #expect(!FileManager.default.fileExists(atPath: Self.testPlist.path))
    }
}
