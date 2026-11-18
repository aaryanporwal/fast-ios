import Foundation

/// Which services a slim simulator keeps, and why.
public struct SlimProfile: Sendable, Codable, Hashable {
    /// "auto: MyApp.app", "full" or "custom".
    public var name: String
    /// The app this profile was derived from, if any.
    public var appPath: String?
    /// Kept slimmable label -> the reasons it is kept.
    public var keep: [String: [String]]
    /// Labels to disable, sorted.
    public var disable: [String]

    public var disableSet: Set<String> { Set(disable) }
}

public enum Profiler {
    /// Disables every slimmable label. Used when no app is known.
    public static func full(keeping extra: [String] = []) -> SlimProfile {
        var keep: [String: [String]] = [:]
        addKept(extra, to: &keep)
        return build(name: "full", appPath: nil, keep: keep)
    }

    /// `--keep` names (category IDs, category names or labels) as kept labels.
    static func addKept(_ names: [String], to keep: inout [String: [String]]) {
        for (label, given) in KeepNames.expand(names) {
            keep[label, default: []].append(given == label ? "kept with --keep" : "kept with --keep \(given)")
        }
    }

    /// Derives the profile from what the app declares and links.
    ///
    /// `strict` keeps only what the app declares (Info.plist keys, background
    /// modes, entitlements, embedded extensions) and ignores linked
    /// frameworks, which libraries pull in whether the app uses them or not.
    /// Pair it with `heal`, which turns a needed service back on.
    ///
    /// Services `heal` learned for this bundle id are always kept.
    public static func derive(from facts: AppFacts, keeping extra: [String] = [], strict: Bool = false) -> (profile: SlimProfile, matches: [CapabilityRule]) {
        let matches = CapabilityMap.rules.filter { rule in
            if strict, case .framework = rule.trigger { return false }
            return facts.has(rule.trigger)
        }
        var keep: [String: [String]] = [:]
        for rule in matches {
            for label in rule.keep {
                keep[label, default: []].append("\(rule.trigger): \(rule.reason)")
            }
        }
        addKept(extra, to: &keep)
        if let bundleID = facts.bundleIdentifier {
            for (label, learned) in HealStore.learned(for: bundleID) {
                keep[label, default: []].append("learned by heal \(ISO8601DateFormatter().string(from: learned.learnedAt)): the app called \(learned.machService)")
            }
        }
        let name = (strict ? "strict: " : "auto: ") + facts.appName
        return (build(name: name, appPath: facts.appPath, keep: keep), matches)
    }

    public static func build(name: String, appPath: String?, keep: [String: [String]]) -> SlimProfile {
        let slimmable = ServiceCatalog.slimmable
        let kept = keep.filter { slimmable.contains($0.key) }
        let disable = slimmable.subtracting(kept.keys).sorted()
        return SlimProfile(name: name, appPath: appPath, keep: kept, disable: disable)
    }
}
