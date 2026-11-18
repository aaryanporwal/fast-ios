import FastIOSCore
import Foundation

/// Refuses an option a command does not have, before anything runs: before
/// `--set` creates a folder, before the first-run message, and before the
/// command touches a simulator or a LaunchAgent. (`fast-ios on --dry-run`
/// once ignored the unknown option and really turned the switch on.)
enum OptionCheck {
    /// Options every command takes: flag -> takes a value.
    static let global: [String: Bool] = ["--set": true, "--json": false, "--help": false, "-h": false, "--verbose": false,
                                         "--no-color": false]

    /// The options of one command: its help spec, plus the arguments of its
    /// MCP tool (the `--json` path maps --kebab-case flags onto them), plus
    /// the global ones. nil when fast-ios has no such command.
    static func accepted(_ command: String) -> [String: Bool]? {
        let spec = CLISpec.find(command)
        let tool = MCPTools.named(command)
        guard spec != nil || tool != nil || command == "_agent" else { return nil }
        var out = global
        for o in spec?.options ?? [] { out[o.flag] = o.value != nil }
        for (name, schema) in tool?.inputSchema["properties"]?.object ?? [:] {
            out["--" + kebab(name)] = schema["type"]?.string != "boolean"
        }
        return out
    }

    /// The first unknown option and the command it was given to, or nil when
    /// every option is known (or the command itself is unknown: main.swift
    /// reports that).
    static func firstUnknown(_ words: [String]) -> (command: String, option: String)? {
        // The command is the first word that is not an option or the value of --set.
        var i = 0, command: String?
        while i < words.count {
            let w = words[i]
            if w == "--set" { i += 2; continue }
            if !w.hasPrefix("-") { command = w; break }
            i += 1
        }
        let name = command ?? ""
        let bare = global.merging(["--version": false], uniquingKeysWith: { a, _ in a })
        // `help` and `version` (and no command) take only the global options.
        guard let known = (command == nil || name == "help" || name == "version") ? bare : accepted(name) else { return nil }
        i = 0
        var seenCommand = false
        while i < words.count {
            let w = words[i]
            if !seenCommand, w == name { seenCommand = true; i += 1; continue }
            if w.hasPrefix("-"), w != "-" {
                // The parsers read `--flag value` only: `--dry-run=1` once
                // passed this check and then was ignored, so `=` is refused.
                guard !w.contains("="), let takesValue = known[w] else { return (name, w) }
                i += takesValue ? 2 : 1
                continue
            }
            i += 1
        }
        return nil
    }

    static func kebab(_ camel: String) -> String {
        camel.reduce(into: "") { s, c in
            if c.isUppercase { s += "-" + c.lowercased() } else { s.append(c) }
        }
    }
}
