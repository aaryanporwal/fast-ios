import Foundation
import Synchronization
import Testing
@testable import FastIOSCore

/// The app cache: fingerprint rules, the never-reuse checks, eviction and
/// single flight. Every test uses a private cache folder (FASTIOS_CACHE_DIR)
/// and throwaway git repositories; nothing touches ~/Library/Caches.
@Suite("App cache", .serialized, .timeLimit(.minutes(1)))
struct AppCacheTests {
    static let cacheDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fast-ios-appcache-\(UUID().uuidString)", isDirectory: true)
        setenv("FASTIOS_CACHE_DIR", dir.path, 1)
        return dir
    }()

    /// A fresh, empty cache folder for one test.
    static func freshCache() {
        try? FileManager.default.removeItem(at: cacheDir)
        precondition(AppCache.folder.path.hasPrefix(cacheDir.path), "tests must never touch the real app cache")
    }

    // MARK: Helpers

    /// git through Shell.run: it waits on a GCD thread, never on the Swift
    /// concurrency pool (a blocking wait there once hung CI), with a time limit.
    @discardableResult
    static func git(_ dir: URL, _ args: String...) async throws -> String {
        try await Shell.run("/usr/bin/git", ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                                             "-c", "commit.gpgsign=false"] + args, timeout: 30).text
    }

    /// Waits without blocking a thread until `condition` holds, or fails after `seconds`.
    static func waitUntil(_ what: String, seconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw AppCacheError("Timed out after \(seconds) s waiting until \(what).") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    static func write(_ dir: URL, _ path: String, _ text: String) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A git repository with an Xcode-style project, committed.
    static func repo(_ files: [String: String] = [:]) async throws -> URL {
        let dir = TestEnv.temp("repo-\(UUID().uuidString)").resolvingSymlinksInPath()
        try await git(dir, "init", "-q")
        let base = ["App.xcodeproj/project.pbxproj": "// project", "Sources/App.swift": "print(1)\n", ".gitignore": "build/\n.env\n"]
        for (p, t) in base.merging(files, uniquingKeysWith: { _, new in new }) { try write(dir, p, t) }
        try await git(dir, "add", "-A")
        try await git(dir, "commit", "-qm", "init")
        return dir
    }

    static func fp(_ dir: URL, configuration: String = "Debug", variant: String? = nil) async throws -> AppFingerprint {
        var o = FingerprintOptions()
        o.configuration = configuration
        o.variant = variant
        return try await Fingerprinter.compute(dir.path, options: o)
    }

    /// A minimal simulator .app: Info.plist and a 32-byte Mach-O header for
    /// `arch` (enough for `lipo -archs`).
    static func fakeApp(in dir: URL, folder: String = "Build/Products/Debug-iphonesimulator", name: String = "App",
                        bundleID: String? = "dev.example.app", platform: String = "iPhoneSimulator",
                        arch: String = Fingerprinter.hostArch(), jsBundle: Bool = false) throws -> URL {
        let app = dir.appendingPathComponent(folder).appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleExecutable": name, "CFBundleSupportedPlatforms": [platform]]
        if let bundleID { plist["CFBundleIdentifier"] = bundleID }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        let cpu: UInt8 = arch == "x86_64" ? 0x07 : 0x0c
        var header: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe, cpu, 0, 0, 0x01, 0, 0, 0, 0, 0x02, 0, 0, 0]
        header += [UInt8](repeating: 0, count: 16)
        try Data(header).write(to: app.appendingPathComponent(name))
        if jsBundle { try Data("js".utf8).write(to: app.appendingPathComponent("main.jsbundle")) }
        return app
    }

    // MARK: Fingerprint rules (files kind)

    @Test("Two clones at the same commit have the same fingerprint and project ID")
    func sameCommitSameFingerprint() async throws {
        let a = try await Self.repo()
        let b = TestEnv.temp("clone-\(UUID().uuidString)").appendingPathComponent("b")
        try await Self.git(a, "clone", "-q", a.path, b.path)
        let (fa, fb) = (try await Self.fp(a), try await Self.fp(b))
        #expect(fa.kind == .files)
        #expect(fa.hash == fb.hash)
        #expect(fa.projectID == fb.projectID)
    }

    @Test("A dirty file with the committed content keeps the fingerprint; new content changes it, and the diff names it")
    func dirtyFiles() async throws {
        let a = try await Self.repo()
        let base = try await Self.fp(a)
        try Self.write(a, "Sources/App.swift", "print(1)\n")  // same bytes, new mtime
        #expect(try await Self.fp(a).hash == base.hash)
        try Self.write(a, "Sources/App.swift", "print(2)\n")
        let changed = try await Self.fp(a)
        #expect(changed.hash != base.hash)
        let d = FingerprintDiff(from: base.inputs, to: changed.inputs)
        #expect(d.changed == ["file:Sources/App.swift"])
        #expect(d.added.isEmpty && d.removed.isEmpty)
    }

    @Test("Untracked files count, ignored files do not, ignored .env files do")
    func untrackedIgnoredEnv() async throws {
        let a = try await Self.repo()
        let base = try await Self.fp(a)
        try Self.write(a, "build/out.o", "binary")
        #expect(try await Self.fp(a).hash == base.hash, "build/ is ignored")
        try Self.write(a, "Sources/New.swift", "let x = 1\n")
        let withNew = try await Self.fp(a)
        #expect(FingerprintDiff(from: base.inputs, to: withNew.inputs).added == ["file:Sources/New.swift"])
        try FileManager.default.removeItem(at: a.appendingPathComponent("Sources/New.swift"))
        try Self.write(a, ".env", "API=1\n")
        let env1 = try await Self.fp(a)
        #expect(env1.hash != base.hash, ".env is read by builds even when git ignores it")
        try Self.write(a, ".env", "API=2\n")
        #expect(try await Self.fp(a).hash != env1.hash)
    }

    @Test("A renamed file changes the fingerprint by its new path")
    func renamed() async throws {
        let a = try await Self.repo()
        let base = try await Self.fp(a)
        try await Self.git(a, "mv", "Sources/App.swift", "Sources/Main.swift")
        let d = FingerprintDiff(from: base.inputs, to: try await Self.fp(a).inputs)
        #expect(d.added == ["file:Sources/Main.swift"])
        #expect(d.removed == ["file:Sources/App.swift"])
    }

    @Test("Configuration, variant and the executable bit change the fingerprint")
    func settingsChangeIt() async throws {
        let a = try await Self.repo(["run.sh": "echo hi\n"])
        let debug = try await Self.fp(a)
        #expect(try await Self.fp(a, configuration: "Release").hash != debug.hash)
        #expect(try await Self.fp(a, variant: "staging").hash != debug.hash)
        #expect(debug.inputs["xcode"] != nil && debug.inputs["arch"] == Fingerprinter.hostArch())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: a.appendingPathComponent("run.sh").path)
        #expect(try await Self.fp(a).hash != debug.hash)
    }

    @Test("Outside git: every file counts, build output and dependencies do not")
    func noGit() async throws {
        let dir = TestEnv.temp("nogit-\(UUID().uuidString)")
        try Self.write(dir, "App.xcodeproj/project.pbxproj", "// p")
        try Self.write(dir, "Sources/A.swift", "1")
        let base = try await Self.fp(dir)
        #expect(base.projectID == "folder:" + dir.lastPathComponent)
        try Self.write(dir, "build/x.o", "x")
        try Self.write(dir, "node_modules/p/index.js", "x")
        try Self.write(dir, "App.xcodeproj/xcuserdata/me.xcuserdatad/x.plist", "x")
        #expect(try await Self.fp(dir).hash == base.hash)
        try Self.write(dir, "Sources/A.swift", "2")
        #expect(try await Self.fp(dir).hash != base.hash)
    }

    @Test("Unpinned dependencies are never cached: a Podfile without Podfile.lock, remote packages without Package.resolved")
    func unpinned() async throws {
        let pods = try await Self.repo(["ios/Podfile": "pod 'X'"])
        await #expect(throws: NotCacheable.self) { try await Self.fp(pods) }
        try Self.write(pods, "ios/Podfile.lock", "PODS: []")
        _ = try await Self.fp(pods)

        let spm = try await Self.repo(["App.xcodeproj/project.pbxproj": "/* XCRemoteSwiftPackageReference \"Lib\" */"])
        await #expect(throws: NotCacheable.self) { try await Self.fp(spm) }
        try Self.write(spm, "App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved", "{}")
        _ = try await Self.fp(spm)
    }

    // MARK: Expo kind

    /// node on PATH (a file lookup, no process). Without it the Expo tests
    /// are skipped: they need node, never the network.
    static let hasNode = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        .contains { FileManager.default.isExecutableFile(atPath: "\($0)/node") }

    /// A fake `@expo/fingerprint` whose hash is the content of native.txt.
    static func expoRepo() async throws -> URL {
        let cli = """
        const fs = require('fs');
        const h = fs.readFileSync('native.txt', 'utf8').trim();
        console.log(JSON.stringify({hash: h, sources: [{type: 'file', filePath: 'native.txt', hash: h}]}));
        """
        return try await repo(["package.json": "{}", "App.tsx": "export default 1\n", "native.txt": "n1",
                         "node_modules/@expo/fingerprint/bin/cli.js": cli, ".gitignore": "node_modules/\n"])
    }

    @Test("Expo Debug: keyed by native inputs, so a JavaScript change keeps the fingerprint", .enabled(if: hasNode, "needs node on PATH"))
    func expoIgnoresJS() async throws {
        let a = try await Self.expoRepo()
        let base = try await Self.fp(a)
        #expect(base.kind == .expo)
        try Self.write(a, "App.tsx", "export default 2\n")
        #expect(try await Self.fp(a).hash == base.hash)
        try Self.write(a, "native.txt", "n2")
        #expect(try await Self.fp(a).hash != base.hash)
    }

    @Test("Expo Release embeds JavaScript, so it is keyed by every file", .enabled(if: hasNode, "needs node on PATH"))
    func expoReleaseUsesFiles() async throws {
        let a = try await Self.expoRepo()
        let release = try await Self.fp(a, configuration: "Release")
        #expect(release.kind == .files)
        try Self.write(a, "App.tsx", "export default 3\n")
        #expect(try await Self.fp(a, configuration: "Release").hash != release.hash)
    }

    // MARK: Never reuse

    @Test("Never stored: device builds, apps without a bundle ID, other architectures, a configuration that does not match, Expo apps with JavaScript inside")
    func neverStore() async throws {
        Self.freshCache()
        let repo = try await Self.repo()
        let debug = try await Self.fp(repo)
        let dir = TestEnv.temp("apps-\(UUID().uuidString)")
        let device = try Self.fakeApp(in: dir, folder: "Debug-iphoneos", platform: "iPhoneOS")
        await #expect(throws: AppCacheError.self) { try await AppCache.add(device, fingerprint: debug, projectName: "p") }
        let noID = try Self.fakeApp(in: dir, folder: "a/Debug-iphonesimulator", bundleID: nil)
        await #expect(throws: AppCacheError.self) { try await AppCache.add(noID, fingerprint: debug, projectName: "p") }
        let otherArch = try Self.fakeApp(in: dir, folder: "b/Debug-iphonesimulator", arch: Fingerprinter.hostArch() == "arm64" ? "x86_64" : "arm64")
        await #expect(throws: AppCacheError.self) { try await AppCache.add(otherArch, fingerprint: debug, projectName: "p") }
        let release = try Self.fakeApp(in: dir, folder: "c/Release-iphonesimulator")
        await #expect(throws: AppCacheError.self) { try await AppCache.add(release, fingerprint: debug, projectName: "p") }
        let expoFP = AppFingerprint(kind: .expo, inputs: ["expo:hash": "x"], projectID: "p", configuration: "Debug")
        let bundled = try Self.fakeApp(in: dir, folder: "d/Debug-iphonesimulator", jsBundle: true)
        await #expect(throws: AppCacheError.self) { try await AppCache.add(bundled, fingerprint: expoFP, projectName: "p") }
        #expect(AppCache.list().isEmpty, "nothing refused was stored")
    }

    @Test("A stored app is reused only for the same fingerprint and configuration")
    func reuseRules() async throws {
        Self.freshCache()
        let repo = try await Self.repo()
        let debug = try await Self.fp(repo)
        let app = try Self.fakeApp(in: TestEnv.temp("ok-\(UUID().uuidString)"))
        let stored = try await AppCache.add(app, fingerprint: debug, projectName: "repo", buildSeconds: 42)
        #expect(stored.bundleIdentifier == "dev.example.app")
        #expect(AppCache.lookup(debug)?.fingerprint == debug.hash)
        #expect(AppCache.lookup(try await Self.fp(repo, configuration: "Release")) == nil)
        try Self.write(repo, "Sources/App.swift", "print(3)\n")
        #expect(AppCache.lookup(try await Self.fp(repo)) == nil)
        #expect(AppCache.hasEntries(projectID: debug.projectID))
        // A stored app whose .app was removed by hand is no longer an entry.
        try FileManager.default.removeItem(at: AppCache.appURL(stored))
        #expect(AppCache.lookup(debug) == nil)
    }

    @Test("Configuration is read from the build folder name")
    func configurationFromPath() {
        #expect(AppCache.configuration(fromPath: "/x/Build/Products/Debug-iphonesimulator/A.app") == "Debug")
        #expect(AppCache.configuration(fromPath: "/x/Release Staging-iphonesimulator/A.app") == "Release Staging")
        #expect(AppCache.configuration(fromPath: "/x/A.app") == nil)
    }

    // MARK: Eviction

    @Test("Eviction removes the least recently used apps beyond the cap, never the one just stored")
    func eviction() async throws {
        Self.freshCache()
        let dir = TestEnv.temp("evict-\(UUID().uuidString)")
        var fps: [AppFingerprint] = []
        for i in 0..<3 {
            let fp = AppFingerprint(kind: .files, inputs: ["file:x": "\(i)"], projectID: "p", configuration: "Debug")
            _ = try await AppCache.add(try Self.fakeApp(in: dir, folder: "\(i)/Debug-iphonesimulator"), fingerprint: fp, projectName: "p")
            fps.append(fp)
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = AppCache.lookup(fps[0])  // the oldest is now the most recently used
        let one = AppCache.list()[0].sizeBytes
        let removed = AppCache.evict(keeping: fps[2].hash, maxBytes: one * 2)
        #expect(removed.map(\.fingerprint) == [fps[1].hash])
        #expect(Set(AppCache.list().map(\.fingerprint)) == [fps[0].hash, fps[2].hash])
        let all = AppCache.evict(keeping: fps[2].hash, maxBytes: 0)
        #expect(all.map(\.fingerprint) == [fps[0].hash])
        #expect(AppCache.list().map(\.fingerprint) == [fps[2].hash])
        #expect(try AppCache.clear().count == 1)
        #expect(AppCache.list().isEmpty)
    }

    // MARK: Single flight

    static func testFP(_ tag: String = UUID().uuidString) -> AppFingerprint {
        AppFingerprint(kind: .files, inputs: ["file:x": tag], projectID: "p", configuration: "Debug")
    }

    /// A builder that counts its calls, sleeps, and returns a fake app.
    final class Counter: Sendable {
        let count = Mutex(0)
        func bump() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    static func countingBuilder(_ calls: Counter, delay: Duration = .milliseconds(600), fail: Bool = false) throws -> AppBuilder {
        let app = try fakeApp(in: TestEnv.temp("b-\(UUID().uuidString)"))
        return {
            calls.bump()
            try await Task.sleep(for: delay)
            if fail { throw AppCacheError("fake build failed") }
            return (app, 1.5)
        }
    }

    @Test("Five agents missing at once: one builds, the others wait and reuse its app")
    func singleFlight() async throws {
        Self.freshCache()
        let fp = Self.testFP()
        let calls = Counter()
        let build = try Self.countingBuilder(calls)
        let outcomes = try await withThrowingTaskGroup(of: ObtainOutcome.self) { group in
            for _ in 0..<5 {
                group.addTask { try await AppCache.obtain(fp, projectName: "p", command: "fake", poll: 0.05, build: build) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(calls.value == 1)
        let built = outcomes.filter { if case .built = $0 { true } else { false } }
        #expect(built.count == 1)
        #expect(outcomes.allSatisfy {
            switch $0 { case .built(let m), .hit(let m), .waited(let m, _): m.fingerprint == fp.hash }
        })
        // Later callers hit without building.
        let later = try await AppCache.obtain(fp, projectName: "p", command: "fake", build: build)
        #expect({ if case .hit = later { true } else { false } }())
        #expect(calls.value == 1)
    }

    @Test("A builder that crashes releases the lock; a waiter builds instead")
    func crashedBuilder() async throws {
        Self.freshCache()
        let fp = Self.testFP()
        let lock = AppCache.folder.appendingPathComponent(".locks/\(fp.hash).lock")
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Another process takes the build lock, then is killed with SIGKILL.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", "use Fcntl ':flock'; open(my $f, '>>', $ARGV[0]) or die; flock($f, LOCK_EX) or die; sleep 60", lock.path]
        holder.standardInput = FileHandle.nullDevice
        holder.standardOutput = FileHandle.nullDevice
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer { if holder.isRunning { kill(holder.processIdentifier, SIGKILL) } }
        try await Self.waitUntil("perl holds the build lock") {
            let fd = open(lock.path, O_RDWR | O_CLOEXEC)
            defer { if fd >= 0 { close(fd) } }
            guard fd >= 0 else { return false }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
            return true
        }
        let calls = Counter()
        let build = try Self.countingBuilder(calls, delay: .milliseconds(50))
        let pid = holder.processIdentifier
        let killer = Task { try? await Task.sleep(for: .milliseconds(500)); kill(pid, SIGKILL) }
        defer { killer.cancel() }
        let lines = Mutex<[String]>([])
        let outcome = try await AppCache.obtain(fp, projectName: "p", command: "fake", timeout: 30, poll: 0.05,
                                                log: { l in lines.withLock { $0.append(l) } }, build: build)
        try await Self.waitUntil("the killed lock holder exits") { !holder.isRunning }
        #expect({ if case .built = outcome { true } else { false } }())
        #expect(calls.value == 1)
        #expect(lines.withLock { $0 }.contains { $0.contains("waiting for it") })
    }

    @Test("A waiter gives up after its timeout and says who is building")
    func waitTimeout() async throws {
        Self.freshCache()
        let fp = Self.testFP()
        let calls = Counter()
        let slow = try Self.countingBuilder(calls, delay: .seconds(3))
        let first = Task { try await AppCache.obtain(fp, projectName: "p", command: "slow build", poll: 0.05, build: slow) }
        try await Task.sleep(for: .milliseconds(200))
        do {
            _ = try await AppCache.obtain(fp, projectName: "p", command: "other", timeout: 0.5, poll: 0.05, build: slow)
            Issue.record("expected a timeout")
        } catch let e as AppCacheError {
            #expect(e.message.contains("still building"))
            #expect(e.message.contains("slow build"))
        }
        _ = try await first.value
        #expect(calls.value == 1)
    }

    @Test("When the build fails, a waiting agent builds it itself")
    func failedBuilderThenWaiterBuilds() async throws {
        Self.freshCache()
        let fp = Self.testFP()
        let calls = Counter()
        let failing = try Self.countingBuilder(calls, delay: .milliseconds(300), fail: true)
        let working = try Self.countingBuilder(calls, delay: .milliseconds(10))
        let first = Task { try await AppCache.obtain(fp, projectName: "p", command: "a", poll: 0.05, build: failing) }
        try await Task.sleep(for: .milliseconds(100))
        let second = try await AppCache.obtain(fp, projectName: "p", command: "b", poll: 0.05, build: working)
        await #expect(throws: AppCacheError.self) { try await first.value }
        #expect({ if case .built = second { true } else { false } }())
        #expect(calls.value == 2)
    }

    // MARK: Words

    @Test("Ages read as plain words")
    func ages() {
        let now = Date()
        #expect(AppCache.ago(now.addingTimeInterval(-40), now: now) == "40 s ago")
        #expect(AppCache.ago(now.addingTimeInterval(-7200), now: now) == "2 hours ago")
        #expect(AppCache.ago(now.addingTimeInterval(-3 * 86400), now: now) == "3 days ago")
    }
}
