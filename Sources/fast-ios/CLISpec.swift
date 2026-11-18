import FastIOSCore
import Foundation

/// One table for per-command `--help` and the shell completions.
struct CommandSpec {
    struct Option {
        let flag: String
        /// Name of the value, or nil for a boolean flag.
        let value: String?
        let help: String
    }
    let name: String
    let synopsis: String
    let summary: String
    let details: String
    let options: [Option]
    let examples: [String]
    /// What the first positional argument completes to: "simulator", "file", or nil.
    let positional: String?
}

enum CLISpec {
    static let simulatorNote = "<simulator> is a UDID, a unique simulator name, or \"booted\"."
    static let global: [CommandSpec.Option] = [
        .init(flag: "--set", value: "path", help: "Use a custom CoreSimulator device set."),
        .init(flag: "--json", value: nil, help: "Print JSON on stdout (errors too)."),
        .init(flag: "--help", value: nil, help: "Show help for the command."),
        .init(flag: "--no-color", value: nil, help: "Plain text, no colour (also NO_COLOR=1)."),
    ]
    static let keep = CommandSpec.Option(flag: "--keep", value: "category|label", help: "Keep a service on (repeatable): a category ID such as widgets, a category name, or a service label. All of them: `fast-ios catalog`.")
    static let grant = CommandSpec.Option(flag: "--grant", value: "permission", help: "Grant before launch so no prompt appears (repeatable). " + Privacy.helpLine)
    static let app = CommandSpec.Option(flag: "--app", value: "app|folder", help: "Built .app, DerivedData folder, Build/Products or project folder.")
    /// The app cache options of `run` and `shot` (for a project folder).
    static let cacheOptions: [CommandSpec.Option] = [
        .init(flag: "--build", value: "command", help: "On an app cache miss, run this command in the project folder to build the app, store it, and install it. Agents missing on the same app wait for one build."),
        .init(flag: "--built-app", value: "path", help: "Where --build writes the .app, relative to the project. Default: the newest simulator build in the project."),
        .init(flag: "--configuration", value: "name", help: "Build configuration, part of the app fingerprint. Default Debug."),
        .init(flag: "--variant", value: "text", help: "Extra text for the fingerprint, for builds that differ in a way the files do not show (a scheme, a command-line setting)."),
        .init(flag: "--build-timeout", value: "duration", help: "How long to wait for another agent's build of the same app. Default 20m."),
    ]

    static let commands: [CommandSpec] = [
        CommandSpec(name: "run", synopsis: "fast-ios run [--app <app|folder>] [--url <url>] [--keep <category|label>]... [--headless]",
                    summary: "Open your app on a light simulator (finds the app, starts the simulator, installs, launches).",
                    details: "Borrows a simulator from the fast-ios pool (a free running one, else a stopped one, else a new one), makes it light for the app, installs and opens the app. In a terminal it then opens the Simulator window on it. Without --app it finds the newest simulator build for the project in the current folder (Xcode DerivedData, ios/build, build/) and says which one. App cache: in a project folder with a stored app (`fast-ios apps`) or with --build, it first computes the project's fingerprint and reuses the stored app when it matches (Expo: native code only, so JavaScript changes still match), so a worktree with unchanged native code skips the compile. A new simulator starts only while the Mac has memory for it; in a terminal fast-ios waits up to 30 s and then says what to do. The lease ends after --ttl, when the calling process exits, or with `fast-ios release <udid>`.",
                    options: [app,
                              .init(flag: "--url", value: "url", help: "Open this URL after launch (deep link)."),
                              keep,
                              grant,
                              .init(flag: "--runtime", value: "id|name", help: "Runtime, such as \"iOS 27.0\". Default: newest iOS."),
                              .init(flag: "--device-type", value: "id|name", help: "Device type. Default: newest iPhone Pro."),
                              .init(flag: "--ttl", value: "duration", help: "Lease length: 90s, 30m, 2h. Default 30m."),
                              .init(flag: "--simulator", value: "udid", help: "Use this simulator instead of leasing (one you created)."),
                              .init(flag: "--no-launch", value: nil, help: "Install only."),
                              .init(flag: "--headless", value: nil, help: "Do not open the Simulator window. Always headless with --json or when not in a terminal."),
                              .init(flag: "--max-pressure", value: "normal|warning", help: "Start a new simulator even at this memory pressure. Default normal."),
                              .init(flag: "--timeout", value: "duration", help: "How long to wait for memory before stopping with exit code 2. Default 30s in a terminal, 5m with --json or in a script."),
                              .init(flag: "--verbose", value: nil, help: "Also show file paths and counts while it works.")] + cacheOptions,
                    examples: ["cd ~/code/MyApp && fast-ios run",
                               "fast-ios run --build \"xcodebuild -scheme MyApp -destination 'generic/platform=iOS Simulator' -derivedDataPath build build\"",
                               "fast-ios run --app build/Build/Products/Debug-iphonesimulator/MyApp.app --url myapp://settings",
                               "UDID=$(fast-ios run --json | jq -r .udid)"],
                    positional: nil),
        CommandSpec(name: "slim", synopsis: "fast-ios slim <simulator> [--app <app|folder>] [--keep <category|label>]... [--full] [--boot]",
                    summary: "Make one simulator light for an app (an advanced form of `fast-ios on`).",
                    details: "Turns off every service the app does not need. A stopped simulator is changed at once and starts light. A running one is stopped, changed and started again (30 s to 3 min). Without --app: the last app's light set, or --full (every service fast-ios knows off). " + simulatorNote,
                    options: [app, keep,
                              .init(flag: "--full", value: nil, help: "Turn off the whole catalog when no app is given."),
                              .init(flag: "--strict", value: nil, help: "Keep only what the app declares, not what its libraries link; pair with heal."),
                              .init(flag: "--boot", value: nil, help: "Boot a shut-down simulator afterwards.")],
                    examples: ["fast-ios slim booted --app ~/Library/Developer/Xcode/DerivedData/MyApp-abc",
                               "fast-ios slim 4FB5BF30-DBDB-4F07-960E-26C048C38B39 --full --boot",
                               "fast-ios slim booted --app MyApp.app --keep widgets"],
                    positional: "simulator"),
        CommandSpec(name: "on", synopsis: "fast-ios on [--dry-run]",
                    summary: "Keep every simulator light from now on.",
                    details: "Starts a small background helper that makes new simulators light before their first start and turns a service back on when an app turns out to need it. Simulators that are not running become light now; running ones after their next start. Nothing is deleted. If another tool (simslim) already makes your simulators light, fast-ios on stops and tells you what to do. `fast-ios off` undoes all of it.",
                    options: [.init(flag: "--dry-run", value: nil, help: "Say what would change, and change nothing."),
                              .init(flag: "--verbose", value: nil, help: "Also show the helper's name, file and log.")],
                    examples: ["fast-ios on --dry-run", "fast-ios on"], positional: nil),
        CommandSpec(name: "off", synopsis: "fast-ios off [<simulator>] [--boot] [--dry-run]",
                    summary: "Undo fast-ios on: every simulator back to full, no background helper.",
                    details: "With no simulator: stops and removes the helper and makes every simulator full again. Stopped ones are full at once; running ones are not restarted and are fully back to normal after their next start. With a simulator: makes only that one full; a running one is restarted if anything changes. Nothing is deleted. " + simulatorNote,
                    options: [.init(flag: "--boot", value: nil, help: "With a simulator: start it afterwards if it is stopped."),
                              .init(flag: "--dry-run", value: nil, help: "With no simulator: say what would change, and change nothing."),
                              .init(flag: "--verbose", value: nil, help: "Also show what was removed.")],
                    examples: ["fast-ios off", "fast-ios off booted"], positional: "simulator"),
        CommandSpec(name: "uninstall", synopsis: "fast-ios uninstall [--dry-run]",
                    summary: "Remove every trace of fast-ios: turn it off, delete its files, and say what is left for you.",
                    details: "Runs `fast-ios off` (every simulator back to full, the background helper removed), then deletes fast-ios's settings folder, its cache and its log. It lists what only you can remove: the app and the `fast-ios` command link. Simulators are never deleted.",
                    options: [.init(flag: "--dry-run", value: nil, help: "List what would be removed, and change nothing.")],
                    examples: ["fast-ios uninstall --dry-run", "fast-ios uninstall"], positional: nil),
        CommandSpec(name: "profile", synopsis: "fast-ios profile <app|folder> [--keep <category|label>]...",
                    summary: "Show which services the app needs, and why. Changes nothing.",
                    details: "Reads Info.plist, entitlements and linked frameworks. A folder may be DerivedData, Build/Products or the project folder (newest simulator .app wins).",
                    options: [keep], examples: ["fast-ios profile ~/Library/Developer/Xcode/DerivedData/MyApp-abc"], positional: "file"),
        CommandSpec(name: "status", synopsis: "fast-ios status",
                    summary: "List simulators: running or not, light or full, and memory of running ones.",
                    details: "With --verbose, also the light set each one has (\"general\": the set for simulators whose app fast-ios does not know yet; \"auto: MyApp.app\": made for that app), its process count and its UDID.",
                    options: [.init(flag: "--verbose", value: nil, help: "Also show the light set, process count and UDID.")], examples: ["fast-ios status", "fast-ios status --json | jq '.simulators[] | select(.state == \"Booted\")'"],
                    positional: nil),
        CommandSpec(name: "measure", synopsis: "fast-ios measure <simulator>",
                    summary: "How many processes a running simulator has and how much memory they use.",
                    details: simulatorNote, options: [], examples: ["fast-ios measure booted"], positional: "simulator"),
        CommandSpec(name: "watch", synopsis: "fast-ios watch [--app <app|folder>] [--full]",
                    summary: "Make each new simulator light before its first start, in this terminal until Ctrl-C (`on` does this in the background).",
                    details: "Watches the default device set and Xcode's testing set (or --set). Simulators that exist already are never touched.",
                    options: [app, .init(flag: "--full", value: nil, help: "Turn off the whole catalog."),
                              .init(flag: "--strict", value: nil, help: "Keep only what the app declares; pair with --heal."),
                              .init(flag: "--heal", value: "bundle id|app", help: "Also heal every simulator it made light as it starts, for this app.")],
                    examples: ["fast-ios watch --app ~/code/MyApp", "fast-ios watch --set ~/sims --full --json"], positional: nil),
        CommandSpec(name: "catalog", synopsis: "fast-ios catalog",
                    summary: "Every service fast-ios may turn off, by category, with what breaks.",
                    details: "", options: [], examples: ["fast-ios catalog --json | jq '.categories[] | {id, downside}'"], positional: nil),
        CommandSpec(name: "bench", synopsis: "fast-ios bench [--only full,fast-ios,simslim] [--settle 180] [--app <app>]",
                    summary: "Compare full, fast-ios and simslim on throwaway simulators it creates and deletes.",
                    details: "Creates one simulator at a time in a private device set and deletes it afterwards. Measures the make-light command, fresh simulator to light-and-ready, cold boot to ready, processes and memory after --settle seconds, and CLI start-up. simslim is measured when it is on PATH (or --simslim). Takes about 5 minutes per variant. Close other simulators first: memory pressure marks results noisy.",
                    options: [.init(flag: "--only", value: "list", help: "Comma-separated variants. Default: full,fast-ios,simslim."),
                              .init(flag: "--settle", value: "seconds", help: "Wait after the cold boot before measuring. Default 180."),
                              .init(flag: "--repeat", value: "n", help: "Fresh simulators per variant; timings are medians. Default 1."),
                              .init(flag: "--scenario", value: "boot|app|all|parallel|shot|build", help: "boot: make light and start. app: time to the app running. parallel: N agents run at once. shot: first and next shot, with and without the tree (uses one throwaway simulator in the default set). build: a compile with --build against an app cache hit, and the fingerprint's cost (no simulator). app, parallel and shot need --app; build needs --project and --build. Default boot."),
                              .init(flag: "--project", value: "folder", help: "Build scenario: the project folder."),
                              .init(flag: "--build", value: "command", help: "Build scenario: the command that compiles the app. Make it a clean compile (such as a fresh -derivedDataPath) to measure a cold one."),
                              .init(flag: "--built-app", value: "path", help: "Build scenario: where the build writes the .app, relative to the project."),
                              .init(flag: "--configuration", value: "name", help: "Build scenario: build configuration. Default Debug."),
                              .init(flag: "--agents", value: "n", help: "Parallel scenario: concurrent `fast-ios run` calls. Default 3."),
                              .init(flag: "--inject-fault", value: nil, help: "Parallel scenario: agent 1's first boot hangs past 1 s, to exercise replacement."),
                              .init(flag: "--app", value: "app|folder", help: "Bench fast-ios's auto-profile for this app instead of --full."),
                              .init(flag: "--runtime", value: "id|name", help: "Runtime. Default: newest iOS."),
                              .init(flag: "--device-type", value: "id|name", help: "Device type. Default: newest iPhone Pro."),
                              .init(flag: "--runs", value: "n", help: "Runs per CLI start-up measurement. Default 10."),
                              .init(flag: "--simslim", value: "path", help: "simslim binary. Default: from PATH.")],
                    examples: ["fast-ios bench", "fast-ios bench --only full,fast-ios --settle 60 --json > bench.json"], positional: nil),
        CommandSpec(name: "template", synopsis: "fast-ios template [--build | --remove] [--runtime <id>] [--device-type <id>]",
                    summary: "List, build or remove the light templates new pool simulators are copied from.",
                    details: "A template is a shut-down simulator that finished its first boot with every catalog service off. `lease` and `run` clone it instead of creating a simulator, which skips first-boot setup. The first cold lease builds one in the background when memory allows. Templates never get an app. FASTIOS_TEMPLATE=off turns them off.",
                    options: [.init(flag: "--build", value: nil, help: "Build the template now (one boot)."),
                              .init(flag: "--remove", value: nil, help: "Delete the template."),
                              .init(flag: "--runtime", value: "id|name", help: "Runtime. Default: newest with an iPhone Pro."),
                              .init(flag: "--device-type", value: "id|name", help: "Device type. Default: newest iPhone Pro.")],
                    examples: ["fast-ios template", "fast-ios template --build", "fast-ios template --remove --runtime \"iOS 27.0\""],
                    positional: nil),
        CommandSpec(name: "pool", synopsis: "fast-ios pool [--size N] [--idle 30m] [--app <app|folder>]",
                    summary: "Keep N light simulators running and free, so `run` and `lease` start instantly.",
                    details: "Boots only while memory allows (the same admission as lease) and stops short with the reason. The size persists; released leases are kept warm up to it. A free one is shut down when memory gets short (pressure not normal, or less free memory than a new simulator needs), after --idle without use, or when more than N are free. Only simulators fast-ios created and nobody leases are ever shut down. --size 0 shuts down every idle pool simulator. Without --size, shows the settings and each pool simulator.",
                    options: [.init(flag: "--size", value: "n", help: "Free booted simulators to keep (0 to 8)."),
                              app, .init(flag: "--full", value: nil, help: "Turn off the whole catalog."),
                              .init(flag: "--runtime", value: "id|name", help: "Runtime."),
                              .init(flag: "--device-type", value: "id|name", help: "Device type."),
                              .init(flag: "--max-pressure", value: "normal|warning", help: "Highest pressure at which a boot may start."),
                              .init(flag: "--timeout", value: "duration", help: "Wait for memory per boot. Default 60s."),
                              .init(flag: "--idle", value: "duration", help: "Shut down a free running one after this long unused. Default 30m. Persists.")],
                    examples: ["fast-ios pool --size 1 --app ~/code/MyApp", "fast-ios pool --idle 10m", "fast-ios pool --size 0"], positional: nil),
        CommandSpec(name: "doctor", synopsis: "fast-ios doctor",
                    summary: "Check Xcode, runtimes, a conflicting simslim agent, memory and disk; print a fix for each problem.",
                    details: "Read-only. Exit code 1 when a check fails (warnings do not fail).",
                    options: [], examples: ["fast-ios doctor"], positional: nil),
        CommandSpec(name: "lease", synopsis: "fast-ios lease [--app <app|folder>] [--ttl 30m] [--json]",
                    summary: "Borrow a light, running simulator from the shared pool (for scripts and agents).",
                    details: "See `fast-ios help` for every lease option.",
                    options: [app, keep, .init(flag: "--ttl", value: "duration", help: "Lease length. Default 30m."),
                              .init(flag: "--runtime", value: "id|name", help: "Runtime."),
                              .init(flag: "--device-type", value: "id|name", help: "Device type."),
                              .init(flag: "--max-pressure", value: "normal|warning", help: "Start a new simulator even at this memory pressure. Default normal."),
                              .init(flag: "--timeout", value: "duration", help: "How long to wait for memory. Default 30s in a terminal, 5m with --json or in a script.")],
                    examples: ["UDID=$(fast-ios lease --app MyApp.app --json | jq -r .udid)"], positional: nil),
        CommandSpec(name: "release", synopsis: "fast-ios release <udid> [--shutdown]",
                    summary: "End a lease.", details: "",
                    options: [.init(flag: "--shutdown", value: nil, help: "Shut the simulator down too.")],
                    examples: ["fast-ios release $UDID"], positional: "simulator"),
        CommandSpec(name: "leases", synopsis: "fast-ios leases", summary: "List leases, the pool and the queue.",
                    details: "", options: [], examples: ["fast-ios leases --json"], positional: nil),
        CommandSpec(name: "shot", synopsis: "fast-ios shot --app <app|folder> [--udid <simulator>] [--url <url>] [--wait <seconds|text>] [--max-width <px>] [--grant <permission>]...",
                    summary: "Install (if changed) and open the app, then save a screenshot and what is on screen (the accessibility tree).",
                    details: "Uses --udid, else a booted light simulator, else starts a stopped iPhone light. Waits until the screen settles (a small spinner is ignored) or until --wait text appears. The first tree on a simulator takes about 6 s while a test runner starts; it stays up for 5 minutes (FASTIOS_SHOT_IDLE) and later trees take about 1 s. The tree needs the default device set: with --set you get the screenshot only. Pass --udid with a simulator you created.",
                    options: [app,
                              .init(flag: "--udid", value: "simulator", help: "Simulator to use: UDID, unique name or \"booted\"."),
                              .init(flag: "--url", value: "url", help: "Open this deep link after launch (taps Open on iOS's \"Open in …?\" prompt)."),
                              .init(flag: "--wait", value: "seconds|text", help: "A number: longest wait for the screen to settle (default 6). Text: wait for it in a label or identifier (default 20 s)."),
                              .init(flag: "--timeout", value: "seconds", help: "Overrides the wait time."),
                              .init(flag: "--out", value: "dir", help: "Folder for the PNG. Default $TMPDIR/fast-ios-shots."),
                              .init(flag: "--max-width", value: "px", help: "Shrink the PNG to at most this width, such as 400."),
                              .init(flag: "--scale", value: "0-1", help: "Shrink the PNG by this factor, such as 0.33."),
                              grant,
                              .init(flag: "--no-tree", value: nil, help: "Screenshot only."),
                              .init(flag: "--no-session", value: nil, help: "Do not keep the tree runner up after this shot.")] + cacheOptions,
                    examples: ["fast-ios shot --app MyApp.app --udid \"$UDID\" --json",
                               "fast-ios shot --app MyApp.app --udid \"$UDID\" --wait \"Sign in\" --max-width 400",
                               "fast-ios shot --app MyApp.app --udid \"$UDID\" --url myapp://settings --grant photos"],
                    positional: nil),
        CommandSpec(name: "apps", synopsis: "fast-ios apps [why <project> | add <app> --project <folder> | clear [<fingerprint>]]",
                    summary: "The app cache: built apps that `run` and `shot` reuse when the project's native code is unchanged.",
                    details: "Each stored app is keyed by a fingerprint of what it is built from. An Expo project with @expo/fingerprint installed and a Debug build: native inputs only (ios/, native modules, config plugins, app config), so a JavaScript change keeps the fingerprint. Any other project: every file in the git repository, so only identical sources match (another worktree at the same commit). Both add the Xcode version, configuration, Mac architecture, --variant and .env files. With no word: list stored apps. why: say whether the project matches a stored app, and which inputs differ. add: store a built simulator .app. clear: remove one stored app, or all. Stored in ~/Library/Caches/fast-ios/apps (FASTIOS_CACHE_DIR moves it), at most 10 GB (FASTIOS_APP_CACHE_GB); the least recently used go first.",
                    options: [.init(flag: "--project", value: "folder", help: "add: the project folder the app was built from. Default: the current folder."),
                              .init(flag: "--configuration", value: "name", help: "add and why: build configuration. add reads it from the app's folder (Debug-iphonesimulator) when it can."),
                              .init(flag: "--variant", value: "text", help: "add and why: the same --variant as run."),
                              .init(flag: "--build-seconds", value: "seconds", help: "add: how long the build took, so a later reuse can say what it saved.")],
                    examples: ["fast-ios apps",
                               "fast-ios apps add ios/build/Build/Products/Debug-iphonesimulator/MyApp.app --project .",
                               "fast-ios apps why .",
                               "fast-ios apps clear"],
                    positional: nil),
        CommandSpec(name: "heal", synopsis: "fast-ios heal <simulator> --app <bundle id|.app> [--seconds N] [--cooldown 30] [--max-repairs 10]",
                    summary: "Watch the app's log; when it fails to reach a service fast-ios turned off, turn that service on live and remember it.",
                    details: "No restart: the service is enabled and loaded in the running simulator, and every later profile for the app keeps it. Runs until Ctrl-C unless --seconds. With --json, one event per line (healing, repaired, ignored, cap-reached, stopped). " + simulatorNote,
                    options: [.init(flag: "--app", value: "bundle id|.app", help: "The app to watch: an installed bundle id or a built .app."),
                              .init(flag: "--seconds", value: "n", help: "Stop after this many seconds."),
                              .init(flag: "--cooldown", value: "seconds", help: "Ignore the same service for this long after a repair. Default 30."),
                              .init(flag: "--max-repairs", value: "n", help: "Most services to turn on in one run. Default 10.")],
                    examples: ["fast-ios heal booted --app com.example.MyApp",
                               "fast-ios heal \"$UDID\" --app MyApp.app --seconds 60 --json"],
                    positional: "simulator"),
        CommandSpec(name: "repairs", synopsis: "fast-ios repairs [--udid <udid>] [--bundle-id <id>]",
                    summary: "List the services heal turned on, and what each app learned.",
                    details: "Read-only. Learned services are kept in every later profile for that app.",
                    options: [.init(flag: "--udid", value: "udid", help: "Only repairs on this simulator."),
                              .init(flag: "--bundle-id", value: "id", help: "Only repairs for this app."),
                              .init(flag: "--limit", value: "n", help: "Most repairs to list. Default 100.")],
                    examples: ["fast-ios repairs", "fast-ios repairs --bundle-id com.example.MyApp --json"],
                    positional: nil),
        CommandSpec(name: "mcp", synopsis: "fast-ios mcp", summary: "MCP server over stdio for AI coding agents.",
                    details: "Tools: \(MCPTools.all.map(\.name).joined(separator: ", ")). Add to .mcp.json: {\"mcpServers\": {\"fast-ios\": {\"command\": \"fast-ios\", \"args\": [\"mcp\"]}}}",
                    options: [], examples: ["claude mcp add --scope user fast-ios -- fast-ios mcp"], positional: nil),
        CommandSpec(name: "completions", synopsis: "fast-ios completions <zsh|fish|bash>",
                    summary: "Print a shell completion script.", details: "",
                    options: [], examples: ["fast-ios completions zsh > ~/.zfunc/_fast-ios",
                                            "fast-ios completions fish > ~/.config/fish/completions/fast-ios.fish",
                                            "fast-ios completions bash > /opt/homebrew/etc/bash_completion.d/fast-ios"],
                    positional: nil),
    ]

    static func find(_ name: String) -> CommandSpec? { commands.first { $0.name == name } }

    static func help(_ c: CommandSpec) -> String {
        var s = "\(Style.accent(c.synopsis))\n\n\(Style.bold(c.summary))\n"
        if !c.details.isEmpty { s += "\n" + Style.code(wrap(c.details, indent: "")) + "\n" }
        let opts = c.options + global
        s += "\n\(Style.bold("OPTIONS"))\n"
        let width = opts.map { $0.flag.count + ($0.value.map { $0.count + 3 } ?? 0) }.max() ?? 0
        for o in opts {
            let left = o.flag + (o.value.map { " <\($0)>" } ?? "")
            s += "  " + Style.accent(left.padding(toLength: width + 2, withPad: " ", startingAt: 0)) + Style.code(o.help) + "\n"
        }
        s += "\n\(Style.bold("EXAMPLES"))\n" + c.examples.map { "  " + Style.dim("$ ") + $0 }.joined(separator: "\n") + "\n"
        return s
    }

    static func wrap(_ text: String, indent: String, width: Int = 78) -> String {
        var lines: [String] = [], line = indent
        for word in text.split(separator: " ") {
            if line.count + word.count + 1 > width, line != indent { lines.append(line); line = indent }
            line += (line == indent ? "" : " ") + word
        }
        lines.append(line)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Shell completions

enum Completions {
    static func script(_ shell: String) throws -> String {
        switch shell {
        case "zsh": zsh()
        case "fish": fish()
        case "bash": bash()
        default: throw UsageError("completions needs zsh, fish or bash; got \"\(shell)\". Example: fast-ios completions zsh > ~/.zfunc/_fast-ios")
        }
    }

    static let names = CLISpec.commands.map(\.name) + ["help"]

    /// Prints simulator UDIDs for completion (used by the generated scripts).
    static let simulators = "xcrun simctl list devices available 2>/dev/null | /usr/bin/grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}'"

    static func zsh() -> String {
        var s = "#compdef fast-ios\n# fast-ios completions for zsh. Generated by `fast-ios completions zsh`.\n\n"
        s += "_fast_ios_sims() {\n  local -a sims\n  sims=(${(f)\"$(\(simulators))\"} booted)\n  _describe 'simulator' sims\n}\n\n"
        s += "_fast_ios() {\n  local -a commands\n  commands=(\n"
        for c in CLISpec.commands {
            s += "    '\(c.name):\(escape(c.summary, quote: "'").replacingOccurrences(of: ":", with: "\\:"))'\n"
        }
        s += "    'help:Show help'\n  )\n  if (( CURRENT == 2 )); then\n    _describe 'command' commands\n    return\n  fi\n  case $words[2] in\n"
        for c in CLISpec.commands {
            s += "    \(c.name))\n      _arguments -s \\\n"
            for o in c.options + CLISpec.global {
                let help = escape(o.help, quote: "'").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                if let v = o.value {
                    let action = v.contains("app") || v == "path" ? "_files" : " "
                    s += "        '*\(o.flag)[\(help)]:\(v):\(action)' \\\n"
                } else {
                    s += "        '\(o.flag)[\(help)]' \\\n"
                }
            }
            switch c.positional {
            case "simulator": s += "        '1:simulator:_fast_ios_sims'\n"
            case "file": s += "        '1:app:_files'\n"
            default: s += "        '*:: :'\n"
            }
            s += "      ;;\n"
        }
        s += "    completions) _values 'shell' zsh fish bash ;;\n    help) _describe 'command' commands ;;\n  esac\n}\n\n_fast_ios \"$@\"\n"
        return s
    }

    static func fish() -> String {
        var s = "# fast-ios completions for fish. Generated by `fast-ios completions fish`.\ncomplete -c fast-ios -f\n"
        s += "function __fast_ios_sims\n    \(simulators)\nend\n"
        for c in CLISpec.commands {
            s += "complete -c fast-ios -n '__fish_use_subcommand' -a \(c.name) -d '\(escape(c.summary, quote: "'"))'\n"
        }
        s += "complete -c fast-ios -n '__fish_use_subcommand' -a help -d 'Show help'\n"
        for c in CLISpec.commands {
            for o in c.options + CLISpec.global {
                let long = String(o.flag.dropFirst(2))
                let req = o.value == nil ? "" : (o.value!.contains("app") || o.value == "path" ? " -r -F" : " -r")
                s += "complete -c fast-ios -n '__fish_seen_subcommand_from \(c.name)' -l \(long)\(req) -d '\(escape(o.help, quote: "'"))'\n"
            }
            if c.positional == "simulator" {
                s += "complete -c fast-ios -n '__fish_seen_subcommand_from \(c.name)' -a '(__fast_ios_sims) booted'\n"
            } else if c.positional == "file" {
                s += "complete -c fast-ios -n '__fish_seen_subcommand_from \(c.name)' -F\n"
            }
        }
        s += "complete -c fast-ios -n '__fish_seen_subcommand_from completions' -a 'zsh fish bash'\n"
        s += "complete -c fast-ios -n '__fish_seen_subcommand_from help' -a '\(names.joined(separator: " "))'\n"
        return s
    }

    static func bash() -> String {
        var s = "# fast-ios completions for bash. Generated by `fast-ios completions bash`.\n_fast_ios() {\n  local cur=${COMP_WORDS[COMP_CWORD]} cmd=${COMP_WORDS[1]}\n"
        s += "  if [[ $COMP_CWORD -eq 1 ]]; then COMPREPLY=($(compgen -W \"\(names.joined(separator: " "))\" -- \"$cur\")); return; fi\n"
        s += "  local opts=\"\"\n  case $cmd in\n"
        for c in CLISpec.commands {
            let flags = (c.options + CLISpec.global).map(\.flag).joined(separator: " ")
            s += "    \(c.name)) opts=\"\(flags)\""
            if c.positional == "simulator" { s += "; [[ $cur != -* ]] && opts=\"$opts $(\(simulators)) booted\"" }
            s += " ;;\n"
        }
        s += "    completions) opts=\"zsh fish bash\" ;;\n    help) opts=\"\(names.joined(separator: " "))\" ;;\n  esac\n"
        s += "  case ${COMP_WORDS[COMP_CWORD-1]} in --app|--set|--simslim) COMPREPLY=($(compgen -f -- \"$cur\")); return ;; esac\n"
        s += "  COMPREPLY=($(compgen -W \"$opts\" -- \"$cur\"))\n}\ncomplete -o default -F _fast_ios fast-ios\n"
        return s
    }

    static func escape(_ s: String, quote: String) -> String {
        quote == "'" ? s.replacingOccurrences(of: "'", with: "'\\''") : s
    }
}
