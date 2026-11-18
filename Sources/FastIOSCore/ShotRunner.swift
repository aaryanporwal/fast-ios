import CryptoKit
import Foundation
import Synchronization

/// Reads a running app's accessibility tree with a tiny XCTest UI-test bundle.
///
/// Why XCTest: it is the only public, headless route on Xcode 27 / iOS 27.
/// The macOS Accessibility API on the Simulator window needs the Simulator app
/// open and an Accessibility grant; everything else (AXRuntime, idb's
/// AccessibilityPlatformTranslation) is private.
///
/// Limits: each read runs `xcodebuild test-without-building` (~15–25 s on an
/// M5), and xcodebuild only sees simulators in the default device set.
public enum ShotRunner {
    public struct Output: Sendable {
        public let root: AXNode
        public let waitTextFound: Bool?
        /// nil unless asked to accept the "Open in …?" prompt.
        public let openPromptAccepted: Bool?
    }

    public struct RunnerError: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// `~/Library/Caches/fast-ios/ax-runner/<hash>`; the hash covers the
    /// templates and the Xcode build, so a new Xcode rebuilds the runner.
    static func cacheFolder() async throws -> URL {
        // `xcodebuild -version` costs ~1.5 s; Xcode's version.plist says the same.
        let developer = try await Shell.run("/usr/bin/xcode-select", ["-p"]).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let versionPlist = URL(fileURLWithPath: developer).deletingLastPathComponent().appendingPathComponent("version.plist")
        let xcode = developer + ((try? String(contentsOf: versionPlist, encoding: .utf8)) ?? "")
        let key = SHA256.hash(data: Data((xcode + ShotRunnerTemplates.testSource + ShotRunnerTemplates.project
                                          + ShotRunnerTemplates.scheme).utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return Leftovers.cacheFolder.appendingPathComponent("ax-runner/\(key)", isDirectory: true)
    }

    /// The `.xctestrun` file of a built runner, building it first if needed.
    /// Returns whether this call compiled it.
    public static func prepare(log: Log = { _ in }) async throws -> (xctestrun: URL, compiled: Bool) {
        let folder = try await cacheFolder()
        if let found = xctestrun(in: folder) { return (found, false) }

        let fm = FileManager.default
        let staging = folder.deletingLastPathComponent()
            .appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let proj = staging.appendingPathComponent("FastIOSAXRunner.xcodeproj", isDirectory: true)
        let schemes = proj.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        let tests = staging.appendingPathComponent("Tests", isDirectory: true)
        try fm.createDirectory(at: schemes, withIntermediateDirectories: true)
        try fm.createDirectory(at: tests, withIntermediateDirectories: true)
        try Data(ShotRunnerTemplates.project.utf8).write(to: proj.appendingPathComponent("project.pbxproj"))
        try Data(ShotRunnerTemplates.scheme.utf8).write(to: schemes.appendingPathComponent("FastIOSAXRunner.xcscheme"))
        try Data(ShotRunnerTemplates.testSource.utf8).write(to: tests.appendingPathComponent("AXSnapshotTests.swift"))

        log("Compiling the accessibility runner once for this Xcode…")
        let result = try await TimedProcess.run(
            "/usr/bin/xcrun",
            ["xcodebuild", "build-for-testing", "-project", proj.path, "-scheme", "FastIOSAXRunner",
             "-destination", "generic/platform=iOS Simulator",
             "-derivedDataPath", staging.appendingPathComponent("dd").path, "-quiet"],
            timeout: .seconds(600), logTo: staging.appendingPathComponent("build.log"))
        guard result.status == 0, xctestrun(in: staging.appendingPathComponent("dd")) != nil else {
            throw RunnerError(message: "Compiling the accessibility runner failed: \(result.tail)")
        }
        // Publish the products atomically, so parallel shots never see half a runner.
        try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: staging.appendingPathComponent("dd/Build/Products"), to: folder)
        } catch where fm.fileExists(atPath: folder.path) {
            // Another shot published first; use theirs.
        }
        guard let found = xctestrun(in: folder) else {
            throw RunnerError(message: "The accessibility runner built, but no .xctestrun is in \(folder.path).")
        }
        return (found, true)
    }

    static func xctestrun(in folder: URL) -> URL? {
        let fm = FileManager.default
        for dir in [folder, folder.appendingPathComponent("Build/Products")] {
            if let name = (try? fm.contentsOfDirectory(atPath: dir.path))?.first(where: { $0.hasSuffix(".xctestrun") }) {
                return dir.appendingPathComponent(name)
            }
        }
        return nil
    }

    /// Optionally taps Open on SpringBoard's "Open in …?" prompt, activates
    /// the app (no relaunch), optionally waits for `waitText` to appear in a
    /// label or identifier, then snapshots the whole tree.
    public static func read(udid: String, bundleID: String, waitText: String?, acceptOpenPrompt: Bool = false,
                            timeout: Duration, xctestrun: URL) async throws -> Output {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("fast-ios-ax-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let out = work.appendingPathComponent("tree.json")

        // xcodebuild passes TEST_RUNNER_<NAME> to the test process as <NAME>.
        var env = ["TEST_RUNNER_FASTIOS_BUNDLE_ID": bundleID, "TEST_RUNNER_FASTIOS_OUT": out.path,
                   "TEST_RUNNER_FASTIOS_TIMEOUT": String(timeout.components.seconds)]
        if let waitText { env["TEST_RUNNER_FASTIOS_WAIT_TEXT"] = waitText }
        if acceptOpenPrompt { env["TEST_RUNNER_FASTIOS_ACCEPT_OPEN"] = "1" }
        let result = try await TimedProcess.run(
            "/usr/bin/xcrun",
            ["xcodebuild", "test-without-building", "-xctestrun", xctestrun.path, "-destination", "id=\(udid)",
             "-only-testing:FastIOSAXRunner/AXSnapshotTests/testSnapshot",
             "-derivedDataPath", work.appendingPathComponent("dd").path,
             "-resultBundlePath", work.appendingPathComponent("result.xcresult").path],
            environment: env, timeout: timeout + .seconds(120), logTo: work.appendingPathComponent("xcodebuild.log"))
        guard let data = try? Data(contentsOf: out) else {
            let why = result.timedOut ? "timed out" : "exited \(result.status)"
            throw RunnerError(message: "The accessibility runner \(why) without a tree: \(result.tail)")
        }
        let decoded = try JSONDecoder().decode(AXRunnerOutput.self, from: data)
        return Output(root: decoded.root, waitTextFound: decoded.waitTextFound,
                      openPromptAccepted: decoded.openPromptAccepted)
    }
}

/// Runs a host tool with extra environment and a timeout, writing its merged
/// output to a file (xcodebuild output can be megabytes). Shell.run has
/// neither, and its callers do not need them.
enum TimedProcess {
    final class KilledFlag: Sendable { let value = Mutex(false) }

    struct Result: Sendable {
        let status: Int32
        let timedOut: Bool
        /// The last lines of output, for error messages.
        let tail: String
    }

    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                    timeout: Duration, logTo log: URL) async throws -> Result {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice

        let killed = KilledFlag()
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let p = process
            p.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { continuation.resume(throwing: error); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(timeout.components.seconds)) {
                if p.isRunning { killed.value.withLock { $0 = true }; p.terminate() }
            }
        }
        try? handle.close()
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let tail = text.split(separator: "\n").suffix(8).joined(separator: "\n")
        return Result(status: status, timedOut: killed.value.withLock { $0 }, tail: tail)
    }
}
