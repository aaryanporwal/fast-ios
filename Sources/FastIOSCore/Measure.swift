import Foundation

public struct SimMeasurement: Sendable, Hashable {
    /// Processes in the simulator's launchd tree, launchd_sim included.
    public let processes: Int
    /// Summed memory of those processes, in bytes.
    public let bytes: Int64
}

public struct SimProcess: Sendable, Hashable {
    public let pid: Int32
    public let name: String
    public let bytes: Int64
}

/// Memory of a booted simulator: every process under its launchd_sim.
public enum Measure {
    /// Cheap enough to poll: the process table from sysctl and each process's
    /// phys_footprint (top's MEM column, the Activity Monitor number) from
    /// proc_pid_rusage, with no subprocess. Falls back to pgrep, ps and top.
    public static func many(_ udids: [String]) async -> [String: SimMeasurement] {
        guard !udids.isEmpty else { return [:] }
        let table = ProcessTable.all()
        let found = ProcessTable.simulatorRoots(table)
        let wanted = udids.compactMap { u in found[u.uppercased()].map { (u, $0) } }
        if wanted.count == udids.count {
            var children: [Int32: [Int32]] = [:]
            for e in table { children[e.ppid, default: []].append(e.pid) }
            return Dictionary(wanted.map { udid, root in
                let pids = descendants(of: root, children: children)
                return (udid, SimMeasurement(processes: pids.count,
                                             bytes: pids.reduce(0) { $0 + (ProcessTable.footprint($1) ?? 0) }))
            }, uniquingKeysWith: { a, _ in a })
        }
        return await manyWithTools(udids)
    }

    static func manyWithTools(_ udids: [String]) async -> [String: SimMeasurement] {
        var roots: [String: Int32] = [:]
        for udid in udids {
            if let pid = await launchdPID(udid) { roots[udid] = pid }
        }
        guard !roots.isEmpty,
              let tree = try? await processTree(),
              let mem = try? await topFootprint() else { return [:] }
        return roots.mapValues { root in
            let pids = descendants(of: root, children: tree.children)
            return SimMeasurement(processes: pids.count, bytes: pids.reduce(0) { $0 + (mem[$1] ?? 0) })
        }
    }

    /// Precise per-process numbers from the `footprint` tool ("Footprint", the
    /// dirty + compressed + swapped memory the process owns). Slower: seconds.
    public static func detailed(_ udid: String) async throws -> [SimProcess] {
        guard let root = await launchdPID(udid) else {
            throw SimctlError(message: "Simulator \(udid) is not booted. Boot it with `xcrun simctl boot \(udid)` (only one you created), then measure.")
        }
        let tree = try await processTree()
        let pids = descendants(of: root, children: tree.children).sorted()
        var result: [SimProcess] = []
        // Keep each command line well under ARG_MAX.
        for chunk in stride(from: 0, to: pids.count, by: 100).map({ Array(pids[$0..<min($0 + 100, pids.count)]) }) {
            let out = try await Shell.run("/usr/bin/footprint", ["-f", "bytes", "--noCategories"] + chunk.map(String.init), check: false)
            let sizes = parseFootprint(out.text)
            for pid in chunk {
                result.append(SimProcess(pid: pid, name: tree.names[pid] ?? "?", bytes: sizes[pid] ?? 0))
            }
        }
        return result.sorted { $0.bytes > $1.bytes }
    }

    static func launchdPID(_ udid: String) async -> Int32? {
        guard let out = try? await Shell.run("/usr/bin/pgrep", ["-f", "\(udid)/data/var/run/launchd_bootstrap"], check: false) else { return nil }
        return out.text.split(whereSeparator: \.isWhitespace).first.flatMap { Int32($0) }
    }

    struct Tree { var children: [Int32: [Int32]] = [:]; var names: [Int32: String] = [:] }

    static func processTree() async throws -> Tree {
        let out = try await Shell.run("/bin/ps", ["-axo", "pid=,ppid=,comm="]).text
        var tree = Tree()
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            tree.children[ppid, default: []].append(pid)
            tree.names[pid] = f[2].split(separator: "/").last.map(String.init) ?? String(f[2])
        }
        return tree
    }

    static func descendants(of root: Int32, children: [Int32: [Int32]]) -> Set<Int32> {
        var seen = Set<Int32>(), stack = [root]
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            stack.append(contentsOf: children[pid] ?? [])
        }
        return seen
    }

    static func topFootprint() async throws -> [Int32: Int64] {
        let out = try await Shell.run("/usr/bin/top", ["-l", "1", "-stats", "pid,mem"]).text
        var mem: [Int32: Int64] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 2, let pid = Int32(f[0]) else { continue }
            mem[pid] = parseSize(String(f[1]))
        }
        return mem
    }

    static func parseSize(_ raw: String) -> Int64 {
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        var mult: Double = 1
        switch s.last {
        case "K": mult = 1024
        case "M": mult = 1024 * 1024
        case "G": mult = 1024 * 1024 * 1024
        case "B": mult = 1
        default: break
        }
        if s.last?.isLetter == true { s.removeLast() }
        return Int64((Double(s) ?? 0) * mult)
    }

    /// Lines like `launchd_sim [3420]: 64-bit    Footprint: 25561008 B (…)`.
    static func parseFootprint(_ text: String) -> [Int32: Int64] {
        var out: [Int32: Int64] = [:]
        for line in text.split(separator: "\n") {
            guard let open = line.lastIndex(of: "["), let close = line[open...].firstIndex(of: "]"),
                  let pid = Int32(line[line.index(after: open)..<close]),
                  let fp = line.range(of: "Footprint: ") else { continue }
            let num = line[fp.upperBound...].prefix { $0.isNumber }
            if let bytes = Int64(num) { out[pid] = bytes }
        }
        return out
    }
}
