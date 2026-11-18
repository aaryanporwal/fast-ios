import FastIOSCore
import Foundation

let healUsage = """
  fast-ios heal <simulator> --app <bundle id|.app> [--seconds N] [--cooldown 30] [--max-repairs 10] [--json]
      Follow the simulator's log; when the app fails to reach a service fast-ios
      turned off, turn it on live (no reboot) and save it to the app's profile.
      Runs until Ctrl-C unless --seconds. --json prints one event per line.
  fast-ios repairs [--udid <udid>] [--bundle-id <id>] [--json]
      Services heal turned on, and what each app learned.
  fast-ios slim … --strict
      Keep only what the app declares, not what its libraries link; pair with heal.
  fast-ios watch --heal <bundle id|.app>
      Also heal every running simulator in the set that fast-ios made light.
"""

/// `heal` streams events, so it runs here even with --json (the MCP tool of
/// the same name needs `seconds` and returns all events at the end).
func runHealCommand(_ words: [String], json: Bool) async throws {
    var simulator: String?, app: String?, seconds: Int?, cooldown: Int?, maxRepairs: Int?
    var i = 0
    while i < words.count {
        let w = words[i]
        func value() -> String { i += 1; return i < words.count ? words[i] : "" }
        switch w {
        case "--app": app = value()
        case "--seconds": seconds = Int(value())
        case "--cooldown": cooldown = Int(value())
        case "--max-repairs": maxRepairs = Int(value())
        case "--json": break
        default: if !w.hasPrefix("--") { simulator = w }
        }
        i += 1
    }
    guard let simulator else { fail("heal needs a simulator: a UDID, a unique name, or \"booted\"") }
    guard let app, !app.isEmpty, !app.hasPrefix("--") else {
        fail("heal needs --app with the app's bundle id (such as com.example.MyApp) or its built .app. Nothing was changed")
    }
    let device = try await Simctl.resolve(simulator)
    let (bundleID, executable) = try await Healer.appIdentity(app, udid: device.udid)
    var options = HealOptions()
    options.duration = seconds.map(TimeInterval.init)
    if let cooldown { options.cooldown = TimeInterval(cooldown) }
    if let maxRepairs { options.maxRepairs = maxRepairs }
    try await Healer.run(device: device, bundleID: bundleID, executable: executable, options: options) { e in
        printHealEvent(e, json: json)
    }
}

func printHealEvent(_ e: HealEvent, json: Bool) {
    if json {
        if let t = try? JSONOutput.encode(e, pretty: false) { print(t) }
        return
    }
    switch e.event {
    case "repaired":
        print("\(e.time) repaired \(e.label ?? "") in \(e.repairMs ?? 0) ms: \(e.why ?? "")")
    case "repair-failed":
        print("\(e.time) could not turn on \(e.label ?? ""): \(e.why ?? "")")
    default:
        print("\(e.time) \(e.event)\(e.label.map { " \($0)" } ?? ""): \(e.why ?? "")")
    }
}

/// `watch --heal`: heal each booted simulator in the set that fast-ios
/// slimmed, one healer per simulator, started when it is seen booted.
func healBootedSimulators(app: String, json: Bool) async {
    // A healer ends when its simulator shuts down (the log stream closes) and
    // removes itself, so the simulator is healed again after its next boot.
    // An actor, not a local Mutex: the child tasks share it, and Swift 6.3
    // rejects a local non-copyable Mutex captured by a `sending` closure.
    let healing = HealingSet()
    await withTaskGroup(of: Void.self) { group in
        while !Task.isCancelled {
            let slimmed = StateStore.load().devices
            for d in (try? await Simctl.listDevices()) ?? [] where d.isBooted && slimmed[d.udid] != nil {
                guard !(await healing.contains(d.udid)),
                      let (bundleID, executable) = try? await Healer.appIdentity(app, udid: d.udid),
                      await healing.insert(d.udid) else { continue }
                group.addTask {
                    try? await Healer.run(device: d, bundleID: bundleID, executable: executable, options: HealOptions()) { e in
                        printHealEvent(e, json: json)
                    }
                    await healing.remove(d.udid)
                }
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
