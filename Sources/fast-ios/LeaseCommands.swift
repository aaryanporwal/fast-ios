import FastIOSCore
import Foundation

let leaseUsage = """
  fast-ios lease [--app <app|folder>] [--runtime <id|"iOS 27.0">] [--device-type <id|name>]
                 [--ttl 30m] [--owner <id>] [--pid <pid>] [--timeout 30s]
                 [--need-mb 1500] [--reserve-mb 2048] [--max-pressure normal|warning]
                 [--allow-existing] [--json]
      Get a light, running simulator. Reuses a free running one, starts a
      stopped one, or creates one, in that order. The lease ends at release, when the
      TTL passes, or when the owner process exits (--pid, else the caller).
      While memory is short a new start waits in a first-come queue (30 s in
      a terminal, 5 min with --json), then stops with exit code 2 and says
      what to do.
  fast-ios release <udid> [--shutdown] [--json]
  fast-ios leases [--json]
"""

/// Text output for lease, release and leases. `--json` never reaches here:
/// main.swift sends it to the MCP tool of the same name, which this also runs.
func runLeaseCommand(_ command: String, _ words: [String]) async throws {
    guard let tool = MCPTools.named(command) else { fail("unknown lease command \(command)") }
    if command == "release", !words.contains(where: { !$0.hasPrefix("--") }) {
        fail(UsageError("release needs the UDID of a leased simulator: `fast-ios release <udid>`. `fast-ios leases` lists them."))
    }
    var words = words
    if command == "lease" {
        _ = try KeepNames.validate(words.indices.filter { words[$0] == "--keep" && $0 + 1 < words.count }.map { words[$0 + 1] })
        if !words.contains("--timeout") {
            words += ["--timeout", "\(Int(LeaseManager.defaultWait(forPerson: isPerson)))s"]
        }
    }
    // Progress goes to stderr, live, so a person sees why it waits.
    let r: JSONValue
    if command == "lease" {
        r = try JSONOutput.value(try await FastIOSCommands.lease(ToolArguments(try tool.cliArguments(words)), log: stderrLog))
    } else {
        r = try await tool.callFromCLI(words)
    }
    func s(_ k: String) -> String { r[k]?.string ?? "" }

    switch command {
    case "lease":
        if s("status") == "refused" {
            let waited: Int = switch r["waitedSeconds"] {
            case .int(let n)?: Int(n)
            case .double(let d)?: Int(d)
            default: 0
            }
            var lines = ["No simulator was leased: after waiting \(waited) s, \(s("detail"))."]
            lines += r["usage"]?.array?.compactMap(\.string) ?? []
            if !s("nextStep").isEmpty { lines.append("Next: \(s("nextStep"))") }
            FileHandle.standardError.write(Data((styledError(lines.joined(separator: "\n")) + "\n").utf8))
            exit(2)
        }
        print("\(s("udid")) \(s("name")) (\(s("source")), \(s("profile")), until \(s("expiresAt")))")
    case "release":
        if s("status") != "released" {
            let text = "\(s("udid")) is not leased, so nothing was released. `fast-ios leases` lists the current leases."
            FileHandle.standardError.write(Data((styledError(text) + "\n").utf8))
            exit(ExitCode.failure)
        }
        print("Released \(s("udid")).")
    default:
        let rows = r["leases"]?.array ?? []
        if rows.isEmpty { print("No leases.") }
        for row in rows {
            let gone = row["ownerAlive"]?.bool == false ? " (owner gone)" : ""
            let left: Int64 = if case .int(let n)? = row["remainingSeconds"] { n / 60 } else { 0 }
            print("\(row["udid"]?.string ?? "") \(row["name"]?.string ?? "") · \(row["owner"]?.string ?? "")\(gone) · \(row["status"]?.string ?? "") · \(left) min left")
        }
        let m = r["memory"]
        let avail: Int64 = if case .int(let n)? = m?["availableMB"] { n } else { 0 }
        print("Pool: \(r["pool"]?.array?.count ?? 0) · queue: \(r["queue"]?.array?.count ?? 0) · \(avail) MB available, pressure \(m?["pressure"]?.string ?? "?")")
        let stopped = (r["shutDown"]?.array ?? []).compactMap { d -> PoolTrim.Decision? in
            guard let u = d["udid"]?.string, let why = d["reason"]?.string.flatMap(PoolTrim.Reason.init(rawValue:)) else { return nil }
            return PoolTrim.Decision(udid: u, reason: why)
        }
        printPool(stopped, r["poolStatus"]?.array?.compactMap(\.string) ?? [])
    }
}
