import Foundation

/// One way of taking a shot, measured by `bench --scenario shot`.
public struct BenchShotRow: Encodable, Sendable {
    public let name: String
    /// The shot options, as CLI flags.
    public let flags: String
    /// Median of the whole `shot` call, in milliseconds.
    public let totalMs: Int
    /// Median of the tree part (session start + read, or one xcodebuild run); null without a tree.
    @EncodeNull public var treeMs: Int?
    /// Median wait for the screen to settle (depends on the app's screen, not on fast-ios).
    public let screenMs: Int
    public let screenshotBytes: Int
    public let screenshotWidth: Int
    public let treeElements: Int?
    public let samplesMs: [Int]
}

extension Bench {
    /// `bench --scenario shot`: first shot (runner session starts), next shot
    /// (session reused), a shot without a session (one xcodebuild per tree),
    /// a shot without the tree, and a downscaled one. The tree needs the
    /// default device set, so this creates one simulator there, named
    /// fast-ios-bench-shot, and deletes it at the end.
    static func shotScenario(_ o: BenchOptions, log: Log) async throws -> BenchOutput {
        guard let appPath = o.app else { throw UsageError("The shot scenario needs --app <built .app or folder>.") }
        let previousSet = ProcessInfo.processInfo.environment["FASTIOS_DEVICE_SET"]
        unsetenv("FASTIOS_DEVICE_SET")
        defer { if let previousSet { setenv("FASTIOS_DEVICE_SET", previousSet, 1) } }

        let (runtime, deviceType) = try await LeaseManager.resolveTarget(runtime: o.runtime, deviceType: o.deviceType)
        let pressureBefore = MemoryStatus.read().pressure
        log("Shot scenario: creating fast-ios-bench-shot (\(deviceType) on \(runtime)) in the default device set")
        let udid = try await Simctl.simctl("create", "fast-ios-bench-shot", deviceType, runtime).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [BenchShotRow] = []
        do {
            try await Simctl.bootAndWait(udid)
            _ = try await ShotRunner.prepare(log: log)
            // Install once, so no row pays for it.
            var warm = Shot.Options(appPath: appPath, outDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("fast-ios-bench-shots", isDirectory: true))
            warm.udid = udid
            warm.tree = false
            _ = try await Shot.run(warm, log: log)

            struct Case { let name: String; let flags: String; let configure: (inout Shot.Options) -> Void; let coldSession: Bool }
            let cases = [
                Case(name: "First shot with tree (runner starts)", flags: "", configure: { _ in }, coldSession: true),
                Case(name: "Next shot with tree (runner reused)", flags: "", configure: { _ in }, coldSession: false),
                Case(name: "Shot with tree, no session", flags: "--no-session", configure: { $0.session = false }, coldSession: true),
                Case(name: "Shot without tree", flags: "--no-tree", configure: { $0.tree = false }, coldSession: false),
                Case(name: "Shot without tree, 400 px wide", flags: "--no-tree --max-width 400",
                     configure: { $0.tree = false; $0.maxWidth = 400 }, coldSession: false),
            ]
            var samples: [String: [Shot.Result]] = [:]
            for round in 1...max(1, o.repeats) {
                for c in cases {
                    if c.coldSession { await ShotSession.stopAndWait(udid: udid) }
                    log("[shot] round \(round): \(c.name)")
                    var opts = warm
                    opts.tree = true
                    c.configure(&opts)
                    samples[c.name, default: []].append(try await Shot.run(opts, log: { _ in }))
                }
            }
            for c in cases {
                let rs = samples[c.name] ?? []
                func med(_ f: (Shot.Result) -> Int?) -> Int? {
                    let xs = rs.compactMap(f).map(Double.init)
                    return xs.isEmpty ? nil : Int(median(xs))
                }
                func step(_ r: Shot.Result, _ names: Set<String>) -> Int? {
                    let hits = r.timings.filter { names.contains($0.step) }
                    return hits.isEmpty ? nil : hits.reduce(0) { $0 + $1.ms }
                }
                let last = rs.last
                rows.append(BenchShotRow(
                    name: c.name, flags: c.flags, totalMs: med { $0.totalMs } ?? 0,
                    treeMs: med { step($0, ["treeSession", "tree"]) }, screenMs: med { step($0, ["stableScreen"]) } ?? 0,
                    screenshotBytes: med { $0.screenshotBytes } ?? 0, screenshotWidth: last?.screenshotWidth ?? 0,
                    treeElements: last?.treeElements, samplesMs: rs.map(\.totalMs)))
            }
        } catch {
            await ShotSession.stopAndWait(udid: udid)
            await discard(udid)
            throw error
        }
        await ShotSession.stopAndWait(udid: udid)
        await discard(udid)

        let pressureAfter = MemoryStatus.read().pressure
        let noisy = pressureBefore != "normal" || pressureAfter != "normal"
        var notes = ["Shot scenario: the app was installed before the first row; each row relaunches it. Tree time is the runner session start plus the read, or one xcodebuild run with --no-session.",
                     "Screen time is the wait for this app's screen to settle and depends on the app, not on fast-ios."]
        if noisy { notes.append("Memory pressure was not normal (\(pressureBefore) → \(pressureAfter)): timings are noisy.") }
        return BenchOutput(
            date: ISO8601DateFormatter().string(from: Date()), host: await host(), runtime: runtime, deviceType: deviceType,
            fastIOSProfile: appPath, simslimVersion: nil, settleSeconds: 0, variants: [], app: [], shot: rows, parallel: [],
            capabilities: [], startup: [], noisy: noisy, notes: notes)
    }
}
