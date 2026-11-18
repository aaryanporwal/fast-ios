import Darwin
import Foundation

/// pid, parent, name and start time from sysctl(KERN_PROC_PID), no `ps`.
enum ProcessInfoLite {
    struct Info { let ppid: Int32; let name: String; let startTime: Double }

    static func read(_ pid: Int32) -> Info? {
        guard pid > 0 else { return nil }
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0, kp.kp_proc.p_pid == pid else { return nil }
        let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let tv = kp.kp_proc.p_un.__p_starttime
        return Info(ppid: kp.kp_eproc.e_ppid, name: name, startTime: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// Wrappers that exit right after fast-ios does. An agent's tool call
    /// usually runs `zsh -c 'fast-ios lease …'`; the shell exits at once, so
    /// the owner is the first ancestor that is not one of these.
    static let transient: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "-zsh", "-bash", "-fish",
        "env", "xcrun", "nohup", "timeout", "gtimeout", "script", "time", "caffeinate", "fast-ios",
    ]

    /// The process whose exit should end a lease taken by this process.
    static func ownerAncestor() -> ProcessRef? {
        var pid = getppid()
        for _ in 0..<16 {
            guard let info = read(pid) else { return nil }
            if !transient.contains(info.name) || info.ppid <= 1 {
                return ProcessRef(pid: pid, startTime: info.startTime, name: info.name)
            }
            pid = info.ppid
        }
        return ProcessRef.of(getppid())
    }
}

/// Real memory state of the Mac: the kernel's memory pressure level and the
/// memory the VM can hand out without paging (free + inactive + speculative +
/// purgeable pages).
public struct MemoryStatus: Codable, Sendable, Hashable {
    public let availableMB: Int
    public let totalMB: Int
    /// "normal", "warning" or "critical" (kern.memorystatus_vm_pressure_level).
    public let pressure: String

    public static func read() -> MemoryStatus {
        var pageSize: Int = 16384
        var size = MemoryLayout<Int>.size
        sysctlbyname("hw.pagesize", &pageSize, &size, nil, 0)
        var total: UInt64 = 0
        size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var available = 0
        if result == KERN_SUCCESS {
            let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
                + UInt64(stats.speculative_count) + UInt64(stats.purgeable_count)
            available = Int(pages * UInt64(pageSize) / 1_048_576)
        }
        let pressure = switch level { case 4: "critical"; case 2: "warning"; default: "normal" }
        return MemoryStatus(availableMB: available, totalMB: Int(total / 1_048_576), pressure: pressure)
    }
}

/// When a new boot is allowed.
public struct AdmissionPolicy: Codable, Sendable, Hashable {
    /// Memory one more slim simulator is expected to take. A slim iPhone
    /// simulator measured 829 MB at idle; this adds room for boot and an app.
    public var needMB: Int = 1500
    /// Memory that must stay available after the new simulator.
    public var reserveMB: Int = 2048

    /// Highest kernel pressure level at which a boot may start: "normal"
    /// (default) or "warning". "critical" never admits.
    public var maxPressure: String = "normal"

    public init(needMB: Int? = nil, reserveMB: Int? = nil, maxPressure: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        self.needMB = needMB ?? env["FASTIOS_NEED_MB"].flatMap(Int.init) ?? 1500
        self.reserveMB = reserveMB ?? env["FASTIOS_RESERVE_MB"].flatMap(Int.init) ?? 2048
        self.maxPressure = maxPressure ?? env["FASTIOS_MAX_PRESSURE"] ?? "normal"
    }

    func pressureOK(_ m: MemoryStatus) -> Bool {
        m.pressure == "normal" || (m.pressure == "warning" && maxPressure == "warning")
    }

    /// `pendingBoots` are leases still booting: their memory is not used
    /// yet, so it is subtracted here to stop a burst of requests from all
    /// passing the same check.
    public func admits(_ m: MemoryStatus, pendingBoots: Int) -> Bool {
        pressureOK(m) && m.availableMB - pendingBoots * needMB - needMB >= reserveMB
    }

    public func reason(_ m: MemoryStatus, pendingBoots: Int) -> String {
        if !pressureOK(m) { return "memory pressure is \(m.pressure)" }
        return "\(m.availableMB) MB available, \(pendingBoots) boot(s) pending; a new simulator needs \(needMB) MB and \(reserveMB) MB must stay free"
    }
}
