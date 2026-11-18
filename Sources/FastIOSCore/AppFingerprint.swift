import CryptoKit
import Foundation

/// What identifies "the same simulator app" for the app cache: a hash over
/// named inputs. Two projects with the same fingerprint build the same app.
///
/// Two kinds:
/// - `expo`: an Expo or React Native project with `@expo/fingerprint`
///   installed, built in a Debug configuration. Its inputs are the native
///   ones only (the `ios/` folder, native modules, config plugins, the app
///   config), so a JavaScript change keeps the fingerprint: a Debug
///   simulator build loads its JavaScript from Metro.
/// - `files`: everything else. Every file in the git repository (tracked, or
///   untracked and not ignored), by content. Only identical sources hit.
///
/// Both kinds add the Xcode version, the build configuration, the Mac's
/// architecture, an optional variant, and any `.env` files at the project
/// root or in `ios/` (often ignored by git, often read by builds).
/// When in doubt the fingerprint changes: a miss costs a compile, a wrong
/// reuse costs a wrong app.
public struct AppFingerprint: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case expo, files }

    /// SHA-256 over `inputs`, hex.
    public let hash: String
    public let kind: Kind
    /// Input name -> its hash. Names: "file:<path>", "expo:<source>",
    /// "env:<file>", and the settings "xcode", "configuration", "arch",
    /// "variant", "kind", "schema".
    public let inputs: [String: String]
    /// The same app in another worktree has the same project ID: the git
    /// repository's first commit plus the project's folder inside it.
    public let projectID: String
    public let configuration: String

    /// Short form for people: the first 12 hex digits.
    public var short: String { String(hash.prefix(12)) }

    public init(kind: Kind, inputs: [String: String], projectID: String, configuration: String) {
        var all = inputs
        all["kind"] = kind.rawValue
        all["schema"] = String(AppFingerprint.schema)
        all["configuration"] = configuration
        self.kind = kind
        self.inputs = all
        self.projectID = projectID
        self.configuration = configuration
        self.hash = Self.digest(all)
    }

    /// Bumped when the rules change, so old cache entries stop matching.
    public static let schema = 1

    static func digest(_ inputs: [String: String]) -> String {
        var h = SHA256()
        for (k, v) in inputs.sorted(by: { $0.key < $1.key }) {
            h.update(data: Data("\(k)=\(v)\n".utf8))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// How two fingerprints differ: input names only.
public struct FingerprintDiff: Sendable, Codable, Equatable {
    public var changed: [String] = []
    public var added: [String] = []
    public var removed: [String] = []
    public var isEmpty: Bool { changed.isEmpty && added.isEmpty && removed.isEmpty }

    public init(from old: [String: String], to new: [String: String]) {
        for (k, v) in new.sorted(by: { $0.key < $1.key }) {
            if let o = old[k] { if o != v { changed.append(k) } } else { added.append(k) }
        }
        removed = old.keys.filter { new[$0] == nil }.sorted()
    }
}

/// Why fast-ios will not cache this project at all.
public struct NotCacheable: Error, LocalizedError, Sendable, Equatable {
    public let reason: String
    public var errorDescription: String? { reason }
}

public struct FingerprintOptions: Sendable {
    public var configuration = "Debug"
    /// Free text added to the fingerprint, for builds that differ in ways the
    /// files do not show (a scheme, a build setting on the command line).
    public var variant: String?
    /// Use the `files` kind even when `@expo/fingerprint` is present.
    public var forceFiles = false
    public init() {}
}

public enum Fingerprinter {
    /// Computes the fingerprint of the project in `folder`. Throws
    /// NotCacheable when the dependency versions are not pinned.
    public static func compute(_ folder: String, options: FingerprintOptions = FingerprintOptions()) async throws -> AppFingerprint {
        let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw InspectError(message: "\(root.path) is not a folder. Pass the project folder (the one with your .xcodeproj, Package.swift or package.json).")
        }
        let repo = await gitTopLevel(root)
        let projectID = await projectIdentity(root, repo: repo)
        var inputs: [String: String] = [:]
        let kind: AppFingerprint.Kind
        if !options.forceFiles, isDebug(options.configuration), let cli = expoFingerprintCLI(root) {
            inputs.merge(try await expoInputs(root, cli: cli)) { a, _ in a }
            kind = .expo
        } else {
            let files = try await fileInputs(root, repo: repo)
            let base = repo ?? root
            try checkPinned(files.keys.map { String($0.dropFirst("file:".count)) }) {
                try? String(contentsOf: base.appendingPathComponent($0), encoding: .utf8)
            }
            inputs.merge(files) { a, _ in a }
            kind = .files
        }
        inputs.merge(envFiles(root)) { a, _ in a }
        inputs.merge(await settings(variant: options.variant)) { a, _ in a }
        return AppFingerprint(kind: kind, inputs: inputs, projectID: projectID, configuration: options.configuration)
    }

    static func isDebug(_ configuration: String) -> Bool { configuration.lowercased().contains("debug") }

    // MARK: Settings

    /// Xcode version and build, the Mac's architecture, the variant.
    static func settings(variant: String?) async -> [String: String] {
        var out = ["arch": hostArch(), "xcode": await xcodeVersion()]
        if let variant, !variant.isEmpty { out["variant"] = variant }
        return out
    }

    public static func hostArch() -> String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// "27.2 (27B52)", read from the selected Xcode's version.plist (no
    /// xcodebuild start-up). "unknown" when it cannot be read: then every
    /// such build shares one value, so it is still stable, never wrong
    /// across two known versions.
    public static func xcodeVersion() async -> String {
        var developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        if developer == nil || developer!.isEmpty {
            developer = (try? await Shell.run("/usr/bin/xcode-select", ["-p"]))?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let developer, !developer.isEmpty else { return "unknown" }
        let plist = URL(fileURLWithPath: developer).deletingLastPathComponent().appendingPathComponent("version.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = dict["CFBundleShortVersionString"] as? String else { return "unknown" }
        return "\(version) (\(dict["ProductBuildVersion"] as? String ?? "?"))"
    }

    // MARK: Project identity

    static func gitTopLevel(_ root: URL) async -> URL? {
        guard let r = try? await Shell.run("/usr/bin/git", ["-C", root.path, "rev-parse", "--show-toplevel"], check: false),
              r.status == 0 else { return nil }
        let path = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    /// The repository's first commit plus the folder inside it, so every
    /// worktree of one app shares it. Outside git: the folder's name.
    static func projectIdentity(_ root: URL, repo: URL?) async -> String {
        guard let repo,
              let r = try? await Shell.run("/usr/bin/git", ["-C", root.path, "rev-list", "--max-parents=0", "HEAD"], check: false),
              r.status == 0, let first = r.text.split(separator: "\n").map(String.init).sorted().first else {
            return "folder:" + root.lastPathComponent
        }
        let sub = root.path == repo.path ? "." : String(root.path.dropFirst(repo.path.count + 1))
        return "git:\(first.prefix(12)):\(sub)"
    }

    /// The cheap part of `compute`: the project ID alone (one git call).
    public static func projectID(_ folder: String) async -> String {
        let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        return await projectIdentity(root, repo: await gitTopLevel(root))
    }

    // MARK: Expo

    static func expoFingerprintCLI(_ root: URL) -> URL? {
        let cli = root.appendingPathComponent("node_modules/@expo/fingerprint/bin/cli.js")
        return FileManager.default.fileExists(atPath: cli.path) ? cli : nil
    }

    /// `@expo/fingerprint` with the strict preset (the default "balanced"
    /// one skips the app version and build number, which are in Info.plist).
    static func expoInputs(_ root: URL, cli: URL) async throws -> [String: String] {
        let command = "cd \(shellQuote(root.path)) && exec node \(shellQuote(cli.path)) fingerprint:generate --platform ios --preset strict"
        let r = try await Shell.run("/bin/sh", ["-c", command], check: false, timeout: 120)
        guard r.status == 0,
              let json = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any],
              let hash = json["hash"] as? String, let sources = json["sources"] as? [[String: Any]] else {
            let why = r.stderr.split(separator: "\n").last.map(String.init) ?? "no output"
            throw InspectError(message: "Could not compute the Expo fingerprint (node node_modules/@expo/fingerprint): \(why). Next: run `npm install` (or bun/yarn install) in \(root.path), check that `node` is on PATH, then try again.")
        }
        var out = ["expo:hash": hash]
        for s in sources {
            guard let h = s["hash"] as? String else { continue }
            let id = (s["filePath"] as? String) ?? (s["id"] as? String) ?? "?"
            out["expo:" + id] = h
        }
        return out
    }

    // MARK: Files

    /// "file:<path relative to the repo>" -> "<mode>:<git blob id>", for
    /// every tracked file and every untracked file git does not ignore. Blob
    /// IDs come from the git index for unchanged files and are computed for
    /// changed ones, so a clean and a dirty copy of the same content agree.
    static func fileInputs(_ root: URL, repo: URL?) async throws -> [String: String] {
        guard let repo else { return try walkInputs(root) }
        var map: [String: String] = [:]
        var gitlinks = Set<String>()
        let staged = try await Shell.run("/usr/bin/git", ["-C", repo.path, "ls-files", "-s", "-z"])
        for entry in split0(staged.stdout) {
            // "<mode> <blob> <stage>\t<path>"
            guard let tab = entry.firstIndex(of: "\t") else { continue }
            let meta = entry[..<tab].split(separator: " ")
            let path = String(entry[entry.index(after: tab)...])
            guard meta.count == 3 else { continue }
            map[path] = "\(meta[0]):\(meta[1])"
            if meta[0] == "160000" { gitlinks.insert(path) }
        }
        let status = try await Shell.run("/usr/bin/git", ["-C", repo.path, "--no-optional-locks", "status",
                                                          "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"])
        var entries = split0(status.stdout)[...]
        while let e = entries.popFirst() {
            guard e.count > 3 else { continue }
            let xy = e.prefix(2)
            let path = String(e.dropFirst(3))
            if xy.contains("R") || xy.contains("C") {
                let from = entries.popFirst() ?? ""
                if xy.contains("R") { map[from] = nil }
            }
            if gitlinks.contains(path) {
                throw NotCacheable(reason: "The submodule \(path) has uncommitted changes, so fast-ios cannot tell what the app is built from. Commit them, or build without the app cache.")
            }
            let url = repo.appendingPathComponent(path)
            map[path] = try blobInput(url)
        }
        var out: [String: String] = [:]
        for (path, value) in map { out["file:" + path] = value }
        return out
    }

    /// Outside git: every file under the folder, skipping build output,
    /// dependencies and per-user Xcode state.
    static func walkInputs(_ root: URL) throws -> [String: String] {
        let skipDirs: Set<String> = [".git", "node_modules", "build", "DerivedData", "Pods", ".build", ".expo", "xcuserdata", ".swiftpm"]
        var out: [String: String] = [:]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return out }
        for case let url as URL in e {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true {
                if skipDirs.contains(name) { e.skipDescendants() }
                continue
            }
            if name == ".DS_Store" || name.hasSuffix(".xcuserstate") { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            if let v = try? blobInput(url) { out["file:" + rel] = v }
        }
        return out
    }

    /// "<git mode>:<git blob id>" of a file on disk; "deleted" when missing.
    static func blobInput(_ url: URL) throws -> String {
        let fm = FileManager.default
        if let target = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            return "120000:" + gitBlobID(Data(target.utf8))
        }
        guard fm.fileExists(atPath: url.path) else { return "deleted" }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let mode = fm.isExecutableFile(atPath: url.path) ? "100755" : "100644"
        return "\(mode):" + gitBlobID(data)
    }

    /// git's blob ID: SHA-1 of "blob <size>\0<content>".
    static func gitBlobID(_ data: Data) -> String {
        var h = Insecure.SHA1()
        h.update(data: Data("blob \(data.count)\0".utf8))
        h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `.env` and `.env.*` files at the project root and in `ios/`, by
    /// content, whether or not git ignores them.
    static func envFiles(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        for dir in [root, root.appendingPathComponent("ios")] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name == ".env" || name.hasPrefix(".env.") {
                let url = dir.appendingPathComponent(name)
                let rel = dir == root ? name : "ios/" + name
                if let v = try? blobInput(url) { out["env:" + rel] = v }
            }
        }
        return out
    }

    /// Refuses a project whose dependency versions can float: a Podfile
    /// without a Podfile.lock, or Swift packages fetched from a URL without
    /// a Package.resolved. The same files could then build a different app.
    /// `read` returns a file's text by its path relative to the repository.
    static func checkPinned(_ paths: [String], read: (String) -> String?) throws {
        let set = Set(paths)
        for p in paths where (p as NSString).lastPathComponent == "Podfile" {
            let dir = (p as NSString).deletingLastPathComponent
            let lock = dir.isEmpty ? "Podfile.lock" : dir + "/Podfile.lock"
            if !set.contains(lock) {
                throw NotCacheable(reason: "\(p) has no Podfile.lock next to it, so pod versions can change between builds. Commit Podfile.lock to use the app cache.")
            }
        }
        let hasResolved = paths.contains { ($0 as NSString).lastPathComponent == "Package.resolved" }
        let fetches = paths.contains { p in
            guard p.hasSuffix("project.pbxproj") || (p as NSString).lastPathComponent == "Package.swift", let text = read(p) else { return false }
            return text.contains("XCRemoteSwiftPackageReference") || text.contains(".package(url:")
        }
        if fetches, !hasResolved {
            throw NotCacheable(reason: "The project fetches Swift packages but has no Package.resolved, so their versions can change between builds. Commit Package.resolved to use the app cache.")
        }
    }

    static func split0(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
