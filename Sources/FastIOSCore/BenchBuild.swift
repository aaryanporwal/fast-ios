import Foundation

/// `fast-ios bench --scenario build`: what the app cache saves on one
/// project. Runs the caller's build command once (the compile a miss pays),
/// stores the app in a throwaway cache, then times cache hits (fingerprint +
/// lookup, what a hit pays) and the fingerprint alone. No simulator: install
/// and launch take the same time either way.
public struct BuildBenchOptions: Sendable {
    public var project: String
    public var build: String
    public var builtApp: String?
    public var configuration = "Debug"
    public var repeats = 3
    public init(project: String, build: String) {
        self.project = project
        self.build = build
    }
}

public struct BuildBenchResult: Encodable, Sendable {
    public var schemaVersion = JSONOutput.schemaVersion
    public let scenario = "build"
    public let project: String
    /// expo (native inputs only) or files (every file).
    public let kind: String
    public let fingerprint: String
    public let inputs: Int
    public let xcode: String
    public let mac: String
    public let compileSeconds: Double
    public let fingerprintSeconds: [Double]
    public let fingerprintMedian: Double
    public let hitSeconds: [Double]
    public let hitMedian: Double
    public let savedSeconds: Double
    public let appBytes: Int64
    public let notes: [String]
}

public enum BuildBench {
    public static func run(_ o: BuildBenchOptions, log: @escaping Log = { _ in }) async throws -> BuildBenchResult {
        // A throwaway cache, so the bench never fills or reads the real one.
        let previous = ProcessInfo.processInfo.environment["FASTIOS_CACHE_DIR"]
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("fast-ios-bench-cache-\(UUID().uuidString)")
        setenv("FASTIOS_CACHE_DIR", temp.path, 1)
        defer {
            try? FileManager.default.removeItem(at: temp)
            if let previous { setenv("FASTIOS_CACHE_DIR", previous, 1) } else { unsetenv("FASTIOS_CACHE_DIR") }
        }
        var options = FingerprintOptions()
        options.configuration = o.configuration
        func seconds(_ body: () async throws -> Void) async rethrows -> Double {
            let t0 = ContinuousClock.now
            try await body()
            let d = ContinuousClock.now - t0
            return ((Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 100).rounded() / 100
        }
        log("Fingerprint: one warm-up run, then \(o.repeats) timed runs…")
        var fp = try await Fingerprinter.compute(o.project, options: options)
        var fpTimes: [Double] = []
        for _ in 0..<o.repeats {
            fpTimes.append(try await seconds { fp = try await Fingerprinter.compute(o.project, options: options) })
        }
        log("Compiling with `\(o.build)` (the cost of a miss)…")
        let root = URL(fileURLWithPath: (o.project as NSString).expandingTildeInPath).standardizedFileURL
        let (app, compile) = try await AppCache.runBuild(o.build, in: root, builtApp: o.builtApp, configuration: o.configuration)
        let stored = try await AppCache.add(app, fingerprint: fp, projectName: root.lastPathComponent, buildSeconds: compile)
        log("Timing \(o.repeats) app cache hits (fingerprint + lookup)…")
        var request = AppCacheRequest()
        request.options = options
        var hitTimes: [Double] = []
        for _ in 0..<o.repeats {
            var status = ""
            hitTimes.append(try await seconds {
                status = try await AppCache.resolve(project: o.project, request)?.summary.status ?? "none"
            })
            guard status == "hit" else {
                throw AppCacheError("The project changed while the bench ran (a cache lookup was a \(status), not a hit). Run the bench again on a project nobody is editing.")
            }
        }
        let fpMedian = median(fpTimes), hitMedian = median(hitTimes)
        let rounded = (compile * 10).rounded() / 10
        return BuildBenchResult(
            project: root.lastPathComponent, kind: fp.kind.rawValue, fingerprint: fp.hash, inputs: fp.inputs.count,
            xcode: fp.inputs["xcode"] ?? "unknown", mac: macModel(), compileSeconds: rounded,
            fingerprintSeconds: fpTimes, fingerprintMedian: fpMedian, hitSeconds: hitTimes, hitMedian: hitMedian,
            savedSeconds: ((compile - hitMedian) * 10).rounded() / 10, appBytes: stored.sizeBytes,
            notes: ["The compile is whatever the build command does, run once: give it a fresh -derivedDataPath to measure a cold compile.",
                    "A hit is the fingerprint plus the cache lookup. Installing and launching take the same time either way and are not included.",
                    "Medians of \(o.repeats) runs after one warm-up fingerprint."])
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : ((s[s.count / 2 - 1] + s[s.count / 2]) / 2 * 100).rounded() / 100
    }

    static func macModel() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let cpu = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return cpu.isEmpty ? Fingerprinter.hostArch() : cpu
    }
}
