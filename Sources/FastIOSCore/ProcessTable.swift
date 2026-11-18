import Darwin
import Foundation

/// The host's process table read with sysctl and libproc, no `ps`, `pgrep`
/// or `top`. Used by `status`, which used to spend most of its time in those
/// three tools.
enum ProcessTable {
    struct Entry { let pid: Int32; let ppid: Int32; let name: String }

    /// Every process: pid, parent pid, short name (KERN_PROC_ALL).
    static func all() -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The table can grow between the two calls.
        size += size / 8
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { kp in
            let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return Entry(pid: kp.kp_proc.p_pid, ppid: kp.kp_eproc.e_ppid, name: name)
        }
    }

    /// The process's arguments and environment block (KERN_PROCARGS2), as text.
    static func arguments(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix(size).map { $0 == 0 ? 0x20 : $0 }, as: UTF8.self)
    }

    /// phys_footprint in bytes: the number `top` shows as MEM and Activity
    /// Monitor as Memory.
    static func footprint(_ pid: Int32) -> Int64? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? Int64(info.ri_phys_footprint) : nil
    }

    /// launchd_sim pid of each booted simulator, keyed by UDID. Its command
    /// line names `<device folder>/<UDID>/data/var/run/launchd_bootstrap.plist`.
    static func simulatorRoots(_ table: [Entry]) -> [String: Int32] {
        var roots: [String: Int32] = [:]
        for e in table where e.name == "launchd_sim" {
            guard let args = arguments(e.pid), let r = args.range(of: "/data/var/run/launchd_bootstrap") else { continue }
            let before = args[..<r.lowerBound]
            guard let slash = before.lastIndex(of: "/") else { continue }
            let udid = String(before[before.index(after: slash)...])
            if UUID(uuidString: udid) != nil { roots[udid.uppercased()] = e.pid }
        }
        return roots
    }
}
