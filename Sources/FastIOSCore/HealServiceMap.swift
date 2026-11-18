import Foundation

/// Maps the Mach service names that appear in failure log lines to the
/// launchd labels fast-ios manages, from the runtime's own job plists
/// (`RuntimeRoot/System/Library/Launch{Daemons,Agents}/*.plist`: `Label`
/// and the keys of `MachServices`). Example: com.apple.photos.service ->
/// com.apple.assetsd.
public struct ServiceMap: Sendable {
    public let labelForMach: [String: String]
    public let plistForLabel: [String: String]

    public static func load(runtimeIdentifier: String) async throws -> ServiceMap {
        let root = try await runtimeRoot(runtimeIdentifier)
        var mach: [String: String] = [:], plists: [String: String] = [:]
        let managed = ServiceCatalog.slimmable
        for dir in ["System/Library/LaunchDaemons", "System/Library/LaunchAgents"] {
            let folder = URL(fileURLWithPath: root).appendingPathComponent(dir)
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: file),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = plist["Label"] as? String, managed.contains(label) else { continue }
                plists[label] = file.path
                // A label is also reachable under its own name.
                mach[label] = mach[label] ?? label
                if let services = plist["MachServices"] as? [String: Any] {
                    for name in services.keys { mach[name] = label }
                }
            }
        }
        return ServiceMap(labelForMach: mach, plistForLabel: plists)
    }

    private struct Runtimes: Decodable {
        struct R: Decodable { let identifier: String; let runtimeRoot: String? }
        let runtimes: [R]
    }

    static func runtimeRoot(_ id: String) async throws -> String {
        let list = try JSONDecoder().decode(Runtimes.self, from: try await Simctl.simctl("list", "runtimes", "-j").stdout)
        guard let root = list.runtimes.first(where: { $0.identifier == id })?.runtimeRoot else {
            throw SimctlError(message: "Runtime \(id) has no RuntimeRoot.")
        }
        return root
    }
}
