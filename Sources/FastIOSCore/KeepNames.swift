import Foundation

/// What `--keep` accepts: a category ID as `fast-ios catalog` shows it in
/// brackets (`widgets`), a category's full label (`Widgets & Wallpaper`), or
/// one service's launchd label (`com.apple.chronod`). Anything else is refused
/// with the list of valid names, instead of being silently ignored.
public enum KeepNames {
    /// Labels for one name, or nil when the name is unknown. Case and the
    /// spacing around "&" do not matter for categories.
    public static func labels(for name: String) -> [String]? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if ServiceCatalog.slimmable.contains(trimmed) { return [trimmed] }
        // Never turned off anyway: keeping it is a harmless no-op.
        if NeverDisable.labels[trimmed] != nil { return [] }
        let key = normalise(trimmed)
        if let c = ServiceCatalog.categories.first(where: { normalise($0.id) == key || normalise($0.name) == key }) {
            return c.labels.filter { ServiceCatalog.slimmable.contains($0) }
        }
        return nil
    }

    static func normalise(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " and ", with: "&").filter { !$0.isWhitespace }
    }

    /// Every name expanded to labels; unknown names are dropped. Used where a
    /// name was already checked (the profile builders).
    public static func expand(_ names: [String]) -> [(label: String, given: String)] {
        names.flatMap { name in (labels(for: name) ?? []).map { (label: $0, given: name) } }
    }

    /// Checks every name and returns them unchanged; throws for the first
    /// unknown one with the valid category IDs.
    @discardableResult
    public static func validate(_ names: [String]) throws -> [String] {
        for name in names where labels(for: name) == nil {
            throw UsageError(unknownMessage(name))
        }
        return names
    }

    public static func unknownMessage(_ name: String) -> String {
        let ids = ServiceCatalog.categories.map(\.id).joined(separator: ", ")
        return "--keep does not know \"\(name)\". Nothing was changed. Use a category ID (\(ids)), a category name from `fast-ios catalog`, or a service label such as com.apple.chronod."
    }
}
