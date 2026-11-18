import FastIOSCore
import Foundation

/// `fast-ios template [--build | --remove] [--runtime] [--device-type]`.
func runTemplateCommand(_ words: [String]) async throws {
    let f = Flags(words: words)
    try f.check(against: "template")
    if f.has("--build") || f.has("--remove") {
        let (runtime, deviceType) = try await LeaseManager.resolveTarget(runtime: f.value("--runtime"), deviceType: f.value("--device-type"))
        if f.has("--remove") {
            await Templates.remove(runtime: runtime, deviceType: deviceType, log: stderrLog)
        } else {
            let rec = try await Templates.build(runtime: runtime, deviceType: deviceType, log: stderrLog)
            if jsonMode { print(try JSONOutput.encode(rec, pretty: true)); return }
            print("Template \(rec.name) (\(rec.udid)) ready\(rec.buildSeconds.map { " in \(Bench.fmt($0)) s" } ?? "").")
            return
        }
    }
    let all = Templates.list()
    if jsonMode {
        let value: JSONValue = ["schemaVersion": .int(Int64(JSONOutput.schemaVersion)), "templates": try JSONOutput.value(all)]
        print(try JSONOutput.encode(value, pretty: true)); return
    }
    if all.isEmpty { print("No templates. The first cold `run` or `lease` builds one in the background; or run `fast-ios template --build`.") }
    for t in all {
        let set = t.deviceSet.isEmpty ? "default set" : t.deviceSet
        print("\(t.name) · \(t.ready ? "ready" : "building") · \(t.udid) · \(set)\(t.buildSeconds.map { " · built in \(Bench.fmt($0)) s" } ?? "")")
    }
}
