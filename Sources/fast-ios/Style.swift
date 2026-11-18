import FastIOSCore
import Foundation

/// The CLI's only styling layer. Call sites say what a word means
/// (`Style.good("light")`), never which escape code it gets. Every coloured
/// word keeps its meaning without colour: "light", "full", "ok", "problem".
enum Style {
    /// `--no-color` anywhere on the command line.
    static let noColorFlag = CommandLine.arguments.contains("--no-color")

    static let out: TerminalColor.Depth = TerminalColor.depth(
        isTerminal: isatty(STDOUT_FILENO) == 1, environment: ProcessInfo.processInfo.environment,
        json: CommandLine.arguments.contains("--json"), noColorFlag: noColorFlag)
    /// stderr decides for itself: `fast-ios run > log` still colours its progress on the terminal.
    static let err: TerminalColor.Depth = TerminalColor.depth(
        isTerminal: isatty(STDERR_FILENO) == 1, environment: ProcessInfo.processInfo.environment,
        json: CommandLine.arguments.contains("--json"), noColorFlag: noColorFlag)

    static func accent(_ s: String, to d: TerminalColor.Depth = out) -> String { TerminalColor.paint(s, [.accent, .bold], d) }
    static func good(_ s: String, to d: TerminalColor.Depth = out) -> String { TerminalColor.paint(s, [.good], d) }
    static func caution(_ s: String, to d: TerminalColor.Depth = out) -> String { TerminalColor.paint(s, [.caution], d) }
    static func bad(_ s: String, to d: TerminalColor.Depth = out) -> String { TerminalColor.paint(s, [.bad, .bold], d) }
    static func dim(_ s: String, to d: TerminalColor.Depth = out) -> String { TerminalColor.paint(s, [.dim], d) }
    static func bold(_ s: String, to d: TerminalColor.Depth = out) -> String { TerminalColor.paint(s, [.bold], d) }
    /// Inline `code` spans in a sentence, such as "run `fast-ios on`", get the accent colour.
    static func code(_ sentence: String, to d: TerminalColor.Depth = out) -> String {
        guard d != .none else { return sentence }
        let parts = sentence.split(separator: "`", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return sentence }
        return parts.enumerated().map { i, p in i % 2 == 1 ? TerminalColor.paint(String(p), [.accent], d) : String(p) }.joined()
    }

    /// Columns of the terminal stdout is on; nil when stdout is not a terminal.
    static let terminalWidth: Int? = {
        guard isatty(STDOUT_FILENO) == 1 else { return nil }
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return nil }
        return Int(size.ws_col)
    }()

    /// "light" in green, "full" in yellow: the word stays.
    static func state(light: Bool, to d: TerminalColor.Depth = out) -> String {
        light ? good("light", to: d) : caution("full", to: d)
    }

    /// A short bar: light memory against a full simulator's, in cells. Plain
    /// characters so it reads in monochrome too.
    /// Green for a light simulator, yellow for a full one, like its word.
    static func bar(used: Int, of full: Int, width: Int = 20, light: Bool = true, to d: TerminalColor.Depth = out) -> String {
        guard full > 0, width > 0 else { return "" }
        let filled = max(1, min(width, Int((Double(used) / Double(full) * Double(width)).rounded())))
        let cells = String(repeating: "█", count: filled)
        return (light ? good(cells, to: d) : caution(cells, to: d)) + dim(String(repeating: "░", count: width - filled), to: d)
    }
}

/// An error on stderr: the first word red, the rest plain, so the next step is easy to read.
func styledError(_ message: String) -> String {
    let d = Style.err
    guard d != .none else { return "fast-ios: \(message)" }
    return Style.bad("fast-ios:", to: d) + " " + Style.code(message, to: d)
}
