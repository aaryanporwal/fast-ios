import Darwin
import Foundation

/// Keeps one XCTest runner alive per simulator, so only the first `shot`
/// pays for `xcodebuild` starting a test session (about 10 to 25 s); later
/// shots send a request file and get the tree back in about a second.
///
/// The session is a detached `xcodebuild test-without-building` running
/// `testSession` (its own process group, so it outlives the fast-ios call).
/// It ends by itself after `FASTIOS_SHOT_IDLE` seconds (default 300) with no
/// request, when the simulator shuts down, or on `ShotSession.stop`.
/// While it runs it costs one xcodebuild process on the Mac and the test
/// runner app in the simulator.
public enum ShotSession {
    struct Info: Codable {
        let pid: Int32
        let startTime: Double
        let xctestrun: String
    }

    public static var idleSeconds: Int {
        ProcessInfo.processInfo.environment["FASTIOS_SHOT_IDLE"].flatMap(Int.init) ?? 300
    }

    /// `$TMPDIR/fast-ios-shot-sessions/<udid>`: the test runner in the
    /// simulator reads and writes the host's temp folder directly.
    static func folder(_ udid: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fast-ios-shot-sessions/\(udid)", isDirectory: true)
    }

    static func info(_ dir: URL) -> Info? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    static func isRunning(_ info: Info) -> Bool {
        var status: Int32 = 0
        _ = waitpid(info.pid, &status, WNOHANG) // reap it if it was our child and exited
        return ProcessRef(pid: info.pid, startTime: info.startTime, name: "").isAlive
    }

    /// True when a session for this simulator is running and ready.
    public static func isLive(udid: String) -> Bool {
        let dir = folder(udid)
        guard let info = info(dir) else { return false }
        return isRunning(info) && FileManager.default.fileExists(atPath: dir.appendingPathComponent("heartbeat").path)
    }

    /// Starts a session unless one is running with this runner. Returns true
    /// when this call started it.
    @discardableResult
    public static func ensure(udid: String, xctestrun: URL, log: Log = { _ in }) async throws -> Bool {
        let dir = folder(udid)
        pruneDead(except: udid)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // One starter at a time per simulator.
        let fd = open(dir.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw ShotRunner.RunnerError(message: "Cannot open the session lock in \(dir.path).") }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }

        if let current = info(dir), isRunning(current) {
            if current.xctestrun == xctestrun.path, FileManager.default.fileExists(atPath: dir.appendingPathComponent("heartbeat").path) {
                return false
            }
            kill(current.pid, SIGTERM) // a different runner (new Xcode), or stuck before it was ready
        }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name != "lock" {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }

        log("Starting the accessibility session (once per simulator; later shots reuse it)…")
        let env = ProcessInfo.processInfo.environment.merging([
            "TEST_RUNNER_FASTIOS_SESSION_DIR": dir.path,
            "TEST_RUNNER_FASTIOS_IDLE": String(idleSeconds),
        ]) { $1 }
        let pid = try spawnDetached(
            "/usr/bin/xcrun",
            ["xcodebuild", "test-without-building", "-xctestrun", xctestrun.path, "-destination", "id=\(udid)",
             "-only-testing:FastIOSAXRunner/AXSnapshotTests/testSession",
             "-derivedDataPath", dir.appendingPathComponent("dd").path,
             "-resultBundlePath", dir.appendingPathComponent("result.xcresult").path],
            environment: env, logTo: dir.appendingPathComponent("xcodebuild.log"))
        guard let ref = ProcessRef.of(pid) else {
            throw ShotRunner.RunnerError(message: "xcodebuild exited at once; see \(dir.path)/xcodebuild.log")
        }
        let info = Info(pid: pid, startTime: ref.startTime, xctestrun: xctestrun.path)
        try JSONEncoder().encode(info).write(to: dir.appendingPathComponent("session.json"))

        let deadline = ContinuousClock.now + .seconds(180)
        while !fm.fileExists(atPath: dir.appendingPathComponent("heartbeat").path) {
            guard isRunning(info) else {
                throw ShotRunner.RunnerError(message: "The accessibility session ended before it was ready: \(tail(dir))")
            }
            guard ContinuousClock.now < deadline else {
                kill(pid, SIGTERM)
                throw ShotRunner.RunnerError(message: "The accessibility session was not ready after 180 s: \(tail(dir))")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    /// Sends one read to the running session and waits for the answer.
    public static func read(udid: String, bundleID: String, waitText: String?, acceptOpenPrompt: Bool,
                            timeout: Duration) async throws -> ShotRunner.Output {
        let dir = folder(udid)
        guard let info = info(dir), isRunning(info) else {
            throw ShotRunner.RunnerError(message: "No accessibility session is running for \(udid).")
        }
        let id = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)"
        let out = dir.appendingPathComponent("out-\(id).json")
        let request: [String: Any] = [
            "bundleId": bundleID, "out": out.path, "waitText": waitText ?? "",
            "timeout": Double(timeout.components.seconds), "acceptOpen": acceptOpenPrompt,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        // Written under another name, then renamed: the runner only picks up req-*.json.
        let temp = dir.appendingPathComponent("tmp-\(id)")
        try data.write(to: temp)
        guard rename(temp.path, dir.appendingPathComponent("req-\(id).json").path) == 0 else {
            throw ShotRunner.RunnerError(message: "Cannot queue the request in \(dir.path).")
        }
        defer { try? FileManager.default.removeItem(at: out) }

        let deadline = ContinuousClock.now + timeout + .seconds(30)
        while true {
            if let answer = try? Data(contentsOf: out) {
                if let obj = try? JSONSerialization.jsonObject(with: answer) as? [String: Any], let error = obj["error"] as? String {
                    throw ShotRunner.RunnerError(message: "The accessibility runner failed: \(error)")
                }
                let decoded = try JSONDecoder().decode(AXRunnerOutput.self, from: answer)
                return ShotRunner.Output(root: decoded.root, waitTextFound: decoded.waitTextFound,
                                         openPromptAccepted: decoded.openPromptAccepted)
            }
            guard isRunning(info) else {
                throw ShotRunner.RunnerError(message: "The accessibility session ended during the read: \(tail(dir))")
            }
            guard ContinuousClock.now < deadline else {
                // A session that does not answer is stuck; end it so the next shot starts fresh.
                kill(info.pid, SIGTERM)
                throw ShotRunner.RunnerError(message: "The accessibility session did not answer in time; it was stopped.")
            }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    /// Asks the session to end (it finishes the current read first).
    public static func stop(udid: String) {
        let dir = folder(udid)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("stop").path, contents: nil)
    }

    /// Removes session folders of other simulators whose xcodebuild is gone
    /// and that were last touched over an hour ago (deleted simulators).
    static func pruneDead(except udid: String) {
        let fm = FileManager.default
        let root = folder(udid).deletingLastPathComponent()
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name != udid {
            let dir = root.appendingPathComponent(name)
            if let current = info(dir), isRunning(current) { continue }
            let touched = (try? fm.attributesOfItem(atPath: dir.path)[.modificationDate] as? Date) ?? .distantPast
            if Date().timeIntervalSince(touched) > 3600 { try? fm.removeItem(at: dir) }
        }
    }

    /// Stops the session and waits until its xcodebuild has exited.
    public static func stopAndWait(udid: String, timeout: Duration = .seconds(30)) async {
        guard let info = info(folder(udid)), isRunning(info) else { return }
        stop(udid: udid)
        let deadline = ContinuousClock.now + timeout
        while isRunning(info), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        if isRunning(info) { kill(info.pid, SIGTERM) }
        while isRunning(info) { try? await Task.sleep(for: .milliseconds(100)) }
    }

    static func tail(_ dir: URL) -> String {
        let text = (try? String(contentsOf: dir.appendingPathComponent("xcodebuild.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").suffix(6).joined(separator: "\n")
    }

    /// posix_spawn with POSIX_SPAWN_SETSID: a new session and process group,
    /// so a Ctrl-C or the end of the calling shell does not stop the runner.
    static func spawnDetached(_ executable: String, _ arguments: [String], environment: [String: String],
                              logTo log: URL) throws -> Int32 {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        guard rc == 0 else { throw ShotRunner.RunnerError(message: "Cannot start xcodebuild: \(String(cString: strerror(rc)))") }
        return pid
    }
}
