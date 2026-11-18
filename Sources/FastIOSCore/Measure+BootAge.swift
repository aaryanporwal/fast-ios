import Foundation

extension Measure {
    /// Seconds since each booted simulator's launchd_sim started. Memory keeps
    /// rising for a few minutes after boot, so callers use this to say when a
    /// figure has not settled yet. Read-only: one `pgrep` per device and one `ps`.
    public static func bootAge(_ udids: [String]) async -> [String: TimeInterval] {
        var roots: [String: Int32] = [:]
        for udid in udids {
            if let pid = await launchdPID(udid) { roots[udid] = pid }
        }
        guard !roots.isEmpty,
              let out = try? await Shell.run("/bin/ps", ["-o", "pid=,etime=", "-p", roots.values.map(String.init).joined(separator: ",")], check: false)
        else { return [:] }
        var ages: [Int32: TimeInterval] = [:]
        for line in out.text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count == 2, let pid = Int32(f[0]), let age = parseElapsed(String(f[1])) else { continue }
            ages[pid] = age
        }
        return roots.compactMapValues { ages[$0] }
    }

    /// `ps` etime: `[[dd-]hh:]mm:ss`.
    static func parseElapsed(_ raw: String) -> TimeInterval? {
        var days = 0.0
        var rest = Substring(raw)
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let seconds = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return days * 86_400 + seconds
    }
}
