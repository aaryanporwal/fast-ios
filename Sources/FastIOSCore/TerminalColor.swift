import Foundation

/// Whether and how a stream gets colour. A pure function of its inputs, so
/// every rule has a test; the CLI calls it once per stream (stdout, stderr).
public enum TerminalColor {
    public enum Depth: Sendable, Equatable {
        /// No escape codes at all.
        case none
        /// The 8 basic ANSI colours.
        case basic
        /// The 256-colour palette.
        case palette256
    }

    /// The rules, in order:
    /// 1. `--json` and `--no-color` never colour.
    /// 2. `NO_COLOR` (any value, even empty), `CLICOLOR=0` and `TERM=dumb` turn it off.
    /// 3. `FORCE_COLOR` (any value except "0") or `CLICOLOR_FORCE=1` turn it on, even when piped.
    /// 4. Otherwise colour only when the stream is a terminal.
    /// The depth is 256 colours when TERM or COLORTERM says so, else basic.
    public static func depth(isTerminal: Bool, environment env: [String: String], json: Bool, noColorFlag: Bool) -> Depth {
        if json || noColorFlag { return .none }
        if env["NO_COLOR"] != nil { return .none }
        if env["CLICOLOR"] == "0" { return .none }
        if env["TERM"] == "dumb" { return .none }
        let forced = (env["FORCE_COLOR"].map { $0 != "0" } ?? false) || env["CLICOLOR_FORCE"] == "1"
        guard forced || isTerminal else { return .none }
        let term = env["TERM"] ?? ""
        let colorterm = env["COLORTERM"] ?? ""
        if term.contains("256") || colorterm == "truecolor" || colorterm == "24bit" || env["FORCE_COLOR"] == "2" || env["FORCE_COLOR"] == "3" {
            return .palette256
        }
        return .basic
    }

    /// What each style means. Colours are mid-tone so they read on dark and
    /// light backgrounds: no bright white, no black.
    public enum Role: Sendable, CaseIterable {
        /// The tiger's orange: the one number or name that matters.
        case accent
        /// Light, on, ok.
        case good
        /// Full, warnings.
        case caution
        /// Errors, problems.
        case bad
        /// Secondary text, paths, hints.
        case dim
        case bold
    }

    /// The SGR parameters for a role at a depth ("" at .none).
    public static func sgr(_ role: Role, _ depth: Depth) -> String {
        switch (depth, role) {
        case (.none, _): ""
        case (_, .bold): "1"
        case (_, .dim): "2"
        // 166 (dark orange) and friends hold contrast on white and on near-black.
        case (.palette256, .accent): "38;5;166"
        case (.palette256, .good): "38;5;34"
        case (.palette256, .caution): "38;5;136"
        case (.palette256, .bad): "38;5;160"
        case (.basic, .accent): "33"
        case (.basic, .good): "32"
        case (.basic, .caution): "33"
        case (.basic, .bad): "31"
        }
    }

    public static func paint(_ text: String, _ roles: [Role], _ depth: Depth) -> String {
        let codes = roles.map { sgr($0, depth) }.filter { !$0.isEmpty }
        guard !codes.isEmpty, !text.isEmpty else { return text }
        return "\u{1B}[\(codes.joined(separator: ";"))m\(text)\u{1B}[0m"
    }
}
