/// A group of launchd labels that serve one feature.
public struct ServiceCategory: Sendable, Hashable {
    public let id: String
    public let name: String
    public let description: String
    /// What stops working while this category is off.
    public let downside: String
    /// simslim's rounded median phys_footprint increase when only this
    /// category is kept on (iOS 26.5). Not additive.
    public let approxMemoryMB: Int
    public let labels: [String]
    /// Shown for transparency; never disabled.
    public let alwaysEnabled: [AlwaysEnabledService]
}

public struct AlwaysEnabledService: Sendable, Hashable {
    public let label: String
    public let reason: String
}

extension ServiceCatalog {
    /// Every label a profile may disable. Protected labels are removed even if
    /// a catalog edit lists them by mistake.
    public static let slimmable: Set<String> = {
        var set = Set(categories.flatMap(\.labels))
        set.subtract(NeverDisable.labels.keys)
        return set
    }()

    /// Every label fast-ios writes to: the slimmable set plus the labels it may
    /// only re-enable (to repair state left by older tools).
    public static let managed: Set<String> = slimmable.union(NeverDisable.labels.keys)

    public static func categories(containing label: String) -> [ServiceCategory] {
        categories.filter { $0.labels.contains(label) }
    }
}
