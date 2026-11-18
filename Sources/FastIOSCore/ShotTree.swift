import Foundation

/// One accessibility element, as the XCTest runner writes it
/// (`XCUIElementSnapshot`, public XCTest API).
public struct AXNode: Sendable, Codable, Hashable {
    public var type: String
    public var frame: [Double]
    public var label: String?
    public var id: String?
    public var title: String?
    public var value: String?
    public var placeholder: String?
    public var enabled: Bool?
    public var selected: Bool?
    public var focused: Bool?
    public var children: [AXNode]?

    /// True when the element says nothing on its own: an untitled container.
    var isBareContainer: Bool {
        ["Other", "Group"].contains(type) && label == nil && id == nil && title == nil
            && value == nil && placeholder == nil
    }

    public var count: Int { 1 + (children ?? []).reduce(0) { $0 + $1.count } }
}

/// What the runner writes to its output file.
struct AXRunnerOutput: Decodable {
    let root: AXNode
    let appState: Int?
    let waitTextFound: Bool?
    let waitSeconds: Double?
    let openPromptAccepted: Bool?
}

public enum ShotTree {
    /// One line per element: `Type "label" id=… value="…" [x,y,w,h]`, indented
    /// by depth. Untitled Other/Group containers are dropped and their children
    /// moved up a level, so a SwiftUI view does not print as ten nested Others.
    public static func compact(_ root: AXNode) -> String {
        var lines: [String] = []
        func walk(_ node: AXNode, depth: Int) {
            let printed = !node.isBareContainer || depth == 0
            if printed { lines.append(String(repeating: "  ", count: depth) + line(node)) }
            for child in node.children ?? [] { walk(child, depth: printed ? depth + 1 : depth) }
        }
        walk(root, depth: 0)
        return lines.joined(separator: "\n")
    }

    static func line(_ n: AXNode) -> String {
        var parts = [n.type]
        if let l = n.label { parts.append(quote(l)) }
        if let t = n.title, t != n.label { parts.append("title=\(quote(t))") }
        if let i = n.id, i != n.label { parts.append("id=\(i)") }
        if let v = n.value { parts.append("value=\(quote(v))") }
        if let p = n.placeholder { parts.append("placeholder=\(quote(p))") }
        if n.enabled == false { parts.append("disabled") }
        if n.selected == true { parts.append("selected") }
        if n.focused == true { parts.append("focused") }
        parts.append("[" + n.frame.map { String(Int($0.rounded())) }.joined(separator: ",") + "]")
        return parts.joined(separator: " ")
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
