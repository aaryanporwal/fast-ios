import Foundation

public struct SimDevice: Sendable, Hashable, Identifiable, Codable {
    public let udid: String
    public let name: String
    public let state: String
    public let isAvailable: Bool
    public let runtimeIdentifier: String
    public let deviceTypeIdentifier: String?
    public var id: String { udid }
    public var isBooted: Bool { state == "Booted" }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" -> "iOS 27.0"
    public var runtimeName: String {
        let tail = runtimeIdentifier.split(separator: ".").last.map(String.init) ?? runtimeIdentifier
        let parts = tail.split(separator: "-")
        guard let platform = parts.first else { return tail }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }
}

public struct SimctlError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public enum Simctl {
    private struct ListOutput: Decodable {
        struct Entry: Decodable {
            let udid: String
            let name: String
            let state: String
            let isAvailable: Bool?
            let deviceTypeIdentifier: String?
        }
        let devices: [String: [Entry]]
    }

    /// A device set for the current task only, set with
    /// `Simctl.$deviceSetOverride.withValue(path) { … }`. Library callers
    /// (the Mac app) use this instead of the process-wide environment.
    @TaskLocal public static var deviceSetOverride: String?

    /// A custom CoreSimulator device set: the task-local override, else
    /// `FASTIOS_DEVICE_SET` (the CLI's `--set` sets it). nil means the default set.
    public static var deviceSet: String? {
        if let override = deviceSetOverride, !override.isEmpty { return override }
        return ProcessInfo.processInfo.environment["FASTIOS_DEVICE_SET"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Points every later simctl call at a custom device set, creating the
    /// folder when it does not exist yet (simctl refuses a missing folder
    /// with "Provided set path does not exist"). Returns the full path.
    @discardableResult
    public static func useDeviceSet(_ path: String) throws -> String {
        let full = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: full, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw SimctlError(message: "\(full) is a file, not a folder. Pass a folder for --set, or leave --set out to use your normal simulators.")
            }
        } else {
            do {
                try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
            } catch {
                throw SimctlError(message: "Could not create the folder \(full) for --set (\(error.localizedDescription)). Pick a folder you can write to.")
            }
        }
        setenv("FASTIOS_DEVICE_SET", full, 1)
        return full
    }

    @discardableResult
    static func simctl(_ arguments: String..., check: Bool = true) async throws -> ShellResult {
        let set = deviceSet.map { ["--set", $0] } ?? []
        return try await Shell.run("/usr/bin/xcrun", ["simctl"] + set + arguments, check: check)
    }

    public static func listDevices() async throws -> [SimDevice] {
        let result = try await simctl("list", "devices", "-j")
        let list = try JSONDecoder().decode(ListOutput.self, from: result.stdout)
        return list.devices.flatMap { runtime, entries in
            entries.map {
                SimDevice(udid: $0.udid, name: $0.name, state: $0.state, isAvailable: $0.isAvailable ?? true,
                          runtimeIdentifier: runtime, deviceTypeIdentifier: $0.deviceTypeIdentifier)
            }
        }
        .sorted { ($0.isBooted ? 0 : 1, $0.runtimeIdentifier, $0.name) < ($1.isBooted ? 0 : 1, $1.runtimeIdentifier, $1.name) }
    }

    /// Accepts a UDID, "booted" (exactly one booted device), or a unique name.
    public static func resolve(_ selector: String) async throws -> SimDevice {
        let devices = try await listDevices()
        if let d = devices.first(where: { $0.udid.caseInsensitiveCompare(selector) == .orderedSame }) { return d }
        let matches = selector.lowercased() == "booted"
            ? devices.filter(\.isBooted)
            : devices.filter { $0.name == selector && $0.isAvailable }
        guard matches.count == 1 else {
            let set = deviceSet.map { " in device set \($0)" } ?? ""
            throw SimctlError(message: matches.isEmpty
                ? (selector.lowercased() == "booted"
                    ? "No simulator is booted\(set). Get one with `fast-ios run` or `fast-ios lease`, or pass a UDID from `fast-ios status`."
                    : "No simulator matches \"\(selector)\"\(set). `fast-ios status` lists UDIDs and names.")
                : "\(matches.count) simulators match \"\(selector)\"; pass a UDID (`fast-ios status` lists them).")
        }
        return matches[0]
    }

    public static func device(_ udid: String) async throws -> SimDevice {
        guard let d = try await listDevices().first(where: { $0.udid == udid }) else {
            throw SimctlError(message: "Simulator \(udid) no longer exists.")
        }
        return d
    }

    /// Boots the device and waits until its services are up.
    /// When set (the pool sets it), `bootAndWait` gives up after this many
    /// seconds and throws BootFailure instead of waiting forever.
    @TaskLocal public static var bootTimeout: TimeInterval?

    public static func bootAndWait(_ udid: String) async throws {
        guard let timeout = bootTimeout else {
            try await simctl("bootstatus", udid, "-b")
            return
        }
        // Fault injection for `bench --scenario parallel --inject-fault`: the
        // first boot in this process hangs past a 1 s deadline.
        let injected = ProcessInfo.processInfo.environment["FASTIOS_INJECT_BOOT_TIMEOUT"] == "1" && !FaultOnce.used.swap()
        let limit = injected ? 1 : timeout
        let set = deviceSet.map { ["--set", $0] } ?? []
        do {
            try await Shell.run("/usr/bin/xcrun", ["simctl"] + set + ["bootstatus", udid, "-b"], timeout: limit)
        } catch is ShellTimeout {
            throw BootFailure.timedOut(seconds: Int(limit))
        } catch let e as ShellError {
            throw BootFailure.bootFailed(e.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public static func shutdownAndWait(_ udid: String, timeout: Duration = .seconds(120)) async throws {
        _ = try await simctl("shutdown", udid, check: false)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await device(udid).state == "Shutdown" { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw SimctlError(message: "Simulator \(udid) did not shut down within \(timeout).")
    }

    /// Labels launchd inside the booted simulator reports as disabled.
    public static func printDisabled(_ udid: String) async throws -> Set<String> {
        let out = try await simctl("spawn", udid, "launchctl", "print-disabled", "system").text
        return parseDisabled(out)
    }

    public static func launchctlDisable(_ udid: String, label: String) async throws {
        try await simctl("spawn", udid, "launchctl", "disable", "system/\(label)")
    }

    /// Parses `"label" => disabled` (or `=> true`) lines.
    static func parseDisabled(_ output: String) -> Set<String> {
        var set = Set<String>()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let value = parts[2].replacingOccurrences(of: "=>", with: "").trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("disabled") || value.hasPrefix("true") { set.insert(String(parts[1])) }
        }
        return set
    }
}
