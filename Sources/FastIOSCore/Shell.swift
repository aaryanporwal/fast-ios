import Foundation
import Synchronization

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String
    /// True when the tool was terminated by a `timeout`.
    public var timedOut = false
    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

public struct ShellError: Error, LocalizedError, Sendable {
    public let command: String
    public let status: Int32
    public let stderr: String
    public var errorDescription: String? {
        "\(command) exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// Runs host tools (xcrun, ps, top, codesign). Blocking pipe reads happen on a
/// GCD thread so they never tie up a Swift concurrency thread.
public enum Shell {
    /// `timeout`: terminate the tool after this many seconds and throw
    /// ShellTimeout.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], check: Bool = true,
                           environment: [String: String] = [:], timeout: TimeInterval? = nil) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runBlocking(executable, arguments, environment: environment, timeout: timeout)
                    if result.timedOut, let timeout {
                        let cmd = ([executable] + arguments).joined(separator: " ")
                        continuation.resume(throwing: ShellTimeout(command: cmd, seconds: timeout))
                    } else if check && result.status != 0 {
                        let cmd = ([executable] + arguments).joined(separator: " ")
                        continuation.resume(throwing: ShellError(command: cmd, status: result.status, stderr: result.stderr))
                    } else {
                        continuation.resume(returning: result)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    public static func xcrun(_ arguments: String..., check: Bool = true) async throws -> ShellResult {
        try await run("/usr/bin/xcrun", arguments, check: check)
    }

    /// `environment` entries are added to (or override) the inherited ones.
    static func runBlocking(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                            timeout: TimeInterval? = nil) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Shared with the timeout timer; reaped is set once waitUntilExit returns.
        let flags = TimeoutFlags()
        if let timeout {
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !flags.reaped.withLock({ $0 }) else { return }
                flags.timedOut.withLock { $0 = true }
                kill(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if !flags.reaped.withLock({ $0 }) { kill(pid, SIGKILL) }
                }
            }
        }
        // Drain stderr on its own thread so a chatty tool cannot fill the pipe
        // and block while we wait on stdout.
        let errData = Mutex(Data())
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            errData.withLock { $0 = data }
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        flags.reaped.withLock { $0 = true }
        let stderr = errData.withLock { String(decoding: $0, as: UTF8.self) }
        return ShellResult(status: process.terminationStatus, stdout: outData, stderr: stderr,
                           timedOut: flags.timedOut.withLock { $0 })
    }
}

private final class TimeoutFlags: Sendable {
    let reaped = Mutex(false)
    let timedOut = Mutex(false)
}

public struct ShellTimeout: Error, LocalizedError, Sendable {
    public let command: String
    public let seconds: TimeInterval
    public var errorDescription: String? { "\(command) did not finish within \(Int(seconds)) s" }
}
