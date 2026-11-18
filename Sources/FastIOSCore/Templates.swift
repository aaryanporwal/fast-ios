import Darwin
import Foundation

/// Slim templates: one shut-down simulator per device set, runtime and device
/// type that has already finished its first boot. New pool simulators are
/// `simctl clone`s of it, so they skip first-boot setup (measured: slim boot
/// 14 s fresh, 3 s from a clone). A clone does not copy launchd overrides
/// (they are keyed by UDID), so the lease writes them again as usual.
///
/// A template never gets an app installed and is never leased, so clones
/// carry no app data or caches. Templates are created and deleted only by
/// fast-ios (`fast-ios-template-…`). `FASTIOS_TEMPLATE=off` turns them off.
public struct TemplateRecord: Codable, Sendable, Hashable {
    public let udid: String
    public let name: String
    public let deviceSet: String
    public let runtime: String
    public let deviceType: String
    public var createdAt: Date
    /// False while it is being built.
    public var ready: Bool
    /// The process building it, while not ready.
    public var builder: ProcessRef?
    public var buildSeconds: Double?
}

public struct TemplateState: Codable, Sendable {
    /// Keyed by `Templates.key(set:runtime:deviceType:)`.
    public var templates: [String: TemplateRecord] = [:]
    public init() {}
}

public enum Templates {
    static let prefix = "fast-ios-template-"

    public static var enabled: Bool {
        ProcessInfo.processInfo.environment["FASTIOS_TEMPLATE"]?.lowercased() != "off"
    }

    static var folder: URL { StateStore.url.deletingLastPathComponent() }
    static var fileURL: URL { folder.appendingPathComponent("templates.json") }
    static var lockURL: URL { folder.appendingPathComponent("templates.lock") }

    public static func key(set: String, runtime: String, deviceType: String) -> String {
        "\(set)|\(runtime)|\(deviceType)"
    }

    public static func withLock<T>(_ body: (inout TemplateState) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw LeaseStoreError(message: "Cannot open \(lockURL.path): errno \(errno)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw LeaseStoreError(message: "Cannot lock \(lockURL.path): errno \(errno)") }
        defer { flock(fd, LOCK_UN) }
        var state = (try? Data(contentsOf: fileURL)).flatMap { try? LeaseStore.decoder.decode(TemplateState.self, from: $0) } ?? TemplateState()
        let result = try body(&state)
        try LeaseStore.encoder.encode(state).write(to: fileURL, options: .atomic)
        return result
    }

    /// The ready template's UDID, if one exists and is shut down.
    public static func ready(runtime: String, deviceType: String) async -> String? {
        guard enabled else { return nil }
        let k = key(set: Simctl.deviceSet ?? "", runtime: runtime, deviceType: deviceType)
        guard let rec = try? withLock({ $0.templates[k] }), rec.ready,
              let device = try? await Simctl.device(rec.udid), device.state == "Shutdown", device.isAvailable else { return nil }
        return rec.udid
    }

    /// A new simulator for the pool: a clone of the ready template, or a
    /// plain `simctl create` when there is none (or cloning fails).
    public static func makeDevice(name: String, runtime: String, deviceType: String, log: Log) async throws -> (udid: String, cloned: Bool) {
        if let template = await ready(runtime: runtime, deviceType: deviceType) {
            do {
                let udid = try await Simctl.simctl("clone", template, name).text.trimmingCharacters(in: .whitespacesAndNewlines)
                if UUID(uuidString: udid) != nil {
                    log("Copied \(name) from a light template (a ready-made light simulator), which skips first-start setup.")
                    return (udid, true)
                }
            } catch {
                log("clone from template \(template) failed (\(error.localizedDescription)); creating instead")
                await remove(runtime: runtime, deviceType: deviceType, log: log)
            }
        }
        log("Creating a new simulator, \(name)…")
        let udid = try await Simctl.simctl("create", name, deviceType, runtime).text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (udid, false)
    }

    /// Builds the template: create, write the full slim overrides, boot once
    /// (first-boot setup runs here), shut down. Returns the record.
    @discardableResult
    public static func build(runtime: String, deviceType: String, log: Log) async throws -> TemplateRecord {
        let set = Simctl.deviceSet ?? ""
        let k = key(set: set, runtime: runtime, deviceType: deviceType)
        let started = Date()
        let shortRT = runtime.split(separator: ".").last.map(String.init) ?? runtime
        let shortDT = deviceType.split(separator: ".").last.map(String.init) ?? deviceType
        let name = "\(prefix)\(shortRT)-\(shortDT)".lowercased()

        // Claim the build; a second builder backs off.
        let claimed: Bool = try withLock { state in
            if let r = state.templates[k], (r.ready || r.builder?.isAlive == true) { return false }
            state.templates[k] = TemplateRecord(udid: "", name: name, deviceSet: set, runtime: runtime, deviceType: deviceType,
                                                createdAt: started, ready: false, builder: .current, buildSeconds: nil)
            return true
        }
        guard claimed else {
            if let r = try withLock({ $0.templates[k] }), r.ready { return r }
            throw SimctlError(message: "A template for \(shortDT) on \(shortRT) is already being built by another fast-ios.")
        }
        var udid = ""
        do {
            log("building template \(name)")
            udid = try await Simctl.simctl("create", name, deviceType, runtime).text.trimmingCharacters(in: .whitespacesAndNewlines)
            try withLock { $0.templates[k] = TemplateRecord(udid: udid, name: name, deviceSet: set, runtime: runtime, deviceType: deviceType,
                                                             createdAt: started, ready: false, builder: .current, buildSeconds: nil) }
            try DisabledStore.apply(udid, disable: Profiler.full().disableSet)
            try await Simctl.$bootTimeout.withValue(SimHealth.bootTimeout(memory: .read())) {
                try await Simctl.bootAndWait(udid)
            }
            try await Simctl.shutdownAndWait(udid)
            let seconds = (Date().timeIntervalSince(started) * 10).rounded() / 10
            let rec = TemplateRecord(udid: udid, name: name, deviceSet: set, runtime: runtime, deviceType: deviceType,
                                     createdAt: started, ready: true, builder: nil, buildSeconds: seconds)
            try withLock { $0.templates[k] = rec }
            log("template \(name) ready in \(seconds) s")
            return rec
        } catch {
            _ = try? withLock { $0.templates[k] = nil }
            if !udid.isEmpty { await discard(udid) }
            throw error
        }
    }

    /// Deletes the template (only ever one fast-ios built).
    public static func remove(runtime: String, deviceType: String, log: Log) async {
        let k = key(set: Simctl.deviceSet ?? "", runtime: runtime, deviceType: deviceType)
        guard let rec = try? withLock({ $0.templates.removeValue(forKey: k) }), !rec.udid.isEmpty,
              rec.name.hasPrefix(prefix) else { return }
        log("deleting template \(rec.name)")
        await discard(rec.udid)
    }

    public static func list() -> [TemplateRecord] {
        ((try? withLock { $0.templates }) ?? [:]).values.sorted { $0.createdAt < $1.createdAt }
    }

    static func discard(_ udid: String) async {
        _ = try? await Simctl.simctl("shutdown", udid, check: false)
        _ = try? await Simctl.simctl("delete", udid, check: false)
        try? FileManager.default.removeItem(at: DisabledStore.folder(udid))
    }

    /// Starts `fast-ios template --build` in its own session, so the caller
    /// returns at once. Only from the fast-ios CLI binary, only when no
    /// template exists or is being built, and only when memory admits a boot.
    public static func scheduleBuild(runtime: String, deviceType: String, policy: AdmissionPolicy, log: Log) {
        guard enabled, let exe = Bundle.main.executablePath, URL(fileURLWithPath: exe).lastPathComponent == "fast-ios" else { return }
        let k = key(set: Simctl.deviceSet ?? "", runtime: runtime, deviceType: deviceType)
        if let r = try? withLock({ $0.templates[k] }), r.ready || r.builder?.isAlive == true { return }
        let memory = MemoryStatus.read()
        guard policy.admits(memory, pendingBoots: 0) else {
            log("not building a template now: \(policy.reason(memory, pendingBoots: 0))")
            return
        }
        var args = [exe, "template", "--build", "--runtime", runtime, "--device-type", deviceType]
        if let set = Simctl.deviceSet { args += ["--set", set] }
        if spawnDetached(args) { log("Building a light template in the background, so the next new simulator starts faster.") }
    }

    /// posix_spawn with POSIX_SPAWN_SETSID and stdio on /dev/null.
    static func spawnDetached(_ args: [String]) -> Bool {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [0, 1, 2] as [Int32] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        var cargs = args.map { strdup($0) } + [nil]
        defer { for p in cargs { free(p) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, args[0], &actions, &attr, &cargs, environ) == 0
    }
}
