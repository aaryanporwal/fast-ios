import FastIOSCore
import Foundation

/// `fast-ios shot --app <app> [--udid <sim>] [--url <link>] [--wait <s|text>]
/// [--timeout <s>] [--out <dir>] [--no-tree] [--json]`
enum ShotCommand {
    static let usage = """
      fast-ios shot --app <app|folder> [--udid <simulator>] [--url <deep link>]
                    [--wait <seconds|text>] [--out <dir>] [--max-width <px>] [--scale <0-1>]
                    [--grant <permission>]... [--no-tree] [--no-session] [--json]
          Install (if changed), launch and screenshot the app, with its
          accessibility tree. One call, for agents checking a UI change.
          The first tree on a simulator takes 10 to 25 s; the runner then
          stays up for 5 min (FASTIOS_SHOT_IDLE) and later trees take about 1 s.
    """

    static func run(_ raw: [String]) async throws {
        var values: [String: String] = [:]
        var flags = Set<String>()
        var grants: [String] = []
        let valued: Set<String> = ["--app", "--udid", "--url", "--wait", "--timeout", "--out", "--max-width", "--scale", "--grant",
                                   "--build", "--built-app", "--configuration", "--variant", "--build-timeout"]
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if valued.contains(a) {
                guard i + 1 < raw.count else { fail("\(a) needs a value") }
                if a == "--grant" { grants.append(raw[i + 1]) }
                values[a] = raw[i + 1]; i += 2
            } else if a.hasPrefix("--") {
                flags.insert(a); i += 1
            } else {
                fail("shot: unexpected argument \(a)")
            }
        }
        let unknown = flags.subtracting(["--json", "--no-tree", "--no-session"])
        if !unknown.isEmpty { fail("shot: unknown option \(unknown.sorted().joined(separator: ", "))") }
        guard let app = values["--app"] else { fail("shot needs --app <path to .app or folder>") }
        // A wrong path is the first thing to report, before any note about the tree.
        // A project folder may get its app from the app cache instead.
        if !AppCache.isProjectFolder(app) { _ = try AppInspector.locateApp(app) }

        let outDir = values["--out"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? Shot.Options.defaultOutDir
        var options = Shot.Options(appPath: app, outDir: outDir)
        options.udid = values["--udid"]
        options.url = values["--url"]
        options.tree = !flags.contains("--no-tree")
        options.session = !flags.contains("--no-session")
        if let w = values["--max-width"] {
            guard let px = Int(w), px > 0 else { fail("--max-width needs a positive number of pixels") }
            options.maxWidth = px
        }
        if let s = values["--scale"] {
            guard let f = Double(s), f > 0, f <= 1 else { fail("--scale needs a number above 0 and at most 1") }
            options.scale = f
        }
        options.grant = try Privacy.validate(grants)
        options.cache = try cacheRequest { values[$0] }
        if let wait = values["--wait"] { options.setWait(wait) }
        if let t = values["--timeout"] {
            guard let seconds = Double(t), seconds >= 0 else { fail("--timeout needs seconds") }
            options.timeout = .milliseconds(Int(seconds * 1000))
        }

        // `shot --json` never reaches here: main.swift runs the MCP tool for it.
        if options.tree, Simctl.deviceSet != nil {
            print("Note: no accessibility tree here. These simulators are in a separate folder (--set), and Xcode's test tool only sees your normal simulators. The screenshot still works.")
        }
        let result = try await Shot.run(options, log: log)
        let settle = switch result.screenStability {
        case "identical": "screen settled"
        case "small-animation": "screen settled; a small area kept moving (\(result.changedPercent.map { String(format: "%.2f", $0) } ?? "?")% of the screen) and was ignored"
        default: "screen still changing when the wait ended; the picture may be mid-change"
        }
        print("Screenshot: \(result.screenshot) (\(settle); \(result.screenshotWidth)×\(result.screenshotHeight) px, \(result.screenshotBytes / 1024) KB)")
        if !result.granted.isEmpty { print("Granted before launch: \(result.granted.joined(separator: ", "))") }
        let sim = result.simulator.map { "\($0.name) (\($0.udid), \($0.runtime), \(result.simulatorSource))" } ?? "?"
        print("App: \(result.bundleId) on \(sim)\(result.installed ? ", installed" : "")")
        if let found = result.waitTextFound { print("Wait text \"\(result.waitText ?? "")\": \(found ? "found" : "not found")") }
        if let tree = result.tree {
            print("Accessibility tree (\(result.treeElements ?? 0) elements):")
            print(tree)
        } else if result.treeStatus == "unavailable", Simctl.deviceSet != nil {
            print("Accessibility tree: none (see the note at the top).")
        } else {
            print("Accessibility tree: \(result.treeStatus)\(result.treeNote.map { ". \($0)" } ?? "")")
        }
        print("Timings: " + result.timings.map { "\($0.step) \($0.ms) ms" }.joined(separator: ", ") + "; total \(result.totalMs) ms")
    }
}
