import Foundation

/// What fast-ios reads from a built app to choose its services.
public struct AppFacts: Sendable, Codable {
    public let appPath: String
    public let bundleIdentifier: String?
    public let infoPlistKeys: Set<String>
    public let backgroundModes: Set<String>
    public let entitlements: Set<String>
    public let frameworks: Set<String>
    /// NSExtensionPointIdentifier of each embedded app extension.
    public let extensionPoints: Set<String>

    public var appName: String { URL(fileURLWithPath: appPath).lastPathComponent }

    public func has(_ trigger: Trigger) -> Bool {
        switch trigger {
        case .infoPlistKey(let k): infoPlistKeys.contains(k)
        case .backgroundMode(let m): backgroundModes.contains(m)
        case .entitlement(let e): entitlements.contains(e)
        case .framework(let f): frameworks.contains(f)
        case .appExtension(let p): extensionPoints.contains(p)
        }
    }
}

public struct InspectError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public enum AppInspector {
    /// Accepts a `.app`, or a folder to search (a DerivedData project folder,
    /// `Build/Products`, or an Xcode project folder). In a folder it picks the
    /// most recently built simulator `.app`, skipping index builds.
    public static func locateApp(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw InspectError(message: "\(path) is not a .app or a folder. Pass the built .app, its DerivedData folder, or the project folder.")
        }
        if url.pathExtension == "app" { return url }

        var best: (url: URL, date: Date)?
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let item = walker?.nextObject() as? URL {
            let name = item.lastPathComponent
            if name == "Index.noindex" || name == "SourcePackages" || name == "node_modules" || name == "Pods" {
                walker?.skipDescendants()
                continue
            }
            guard item.pathExtension == "app",
                  item.deletingLastPathComponent().lastPathComponent.hasSuffix("-iphonesimulator") else { continue }
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || date > best!.date { best = (item, date) }
        }
        guard let found = best?.url else {
            throw InspectError(message: "No simulator .app (…-iphonesimulator/*.app) under \(path). Build for an iOS Simulator destination first (Expo: `npx expo run:ios`), or pass the .app itself.")
        }
        return found
    }

    public static func inspect(_ app: URL) async throws -> AppFacts {
        let infoURL = app.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw InspectError(message: "\(app.path) has no readable Info.plist.")
        }
        let modes = Set(info["UIBackgroundModes"] as? [String] ?? [])
        let executable = info["CFBundleExecutable"] as? String ?? app.deletingPathExtension().lastPathComponent
        let mainBinary = app.appendingPathComponent(executable)

        async let entitlements = readEntitlements(app: app, binary: mainBinary)
        async let frameworks = linkedFrameworks(app: app, executable: executable)
        return AppFacts(appPath: app.path, bundleIdentifier: info["CFBundleIdentifier"] as? String,
                        infoPlistKeys: Set(info.keys), backgroundModes: modes,
                        entitlements: await entitlements, frameworks: await frameworks,
                        extensionPoints: extensionPoints(app: app))
    }

    static func extensionPoints(app: URL) -> Set<String> {
        let plugins = app.appendingPathComponent("PlugIns")
        let items = (try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []
        return Set(items.filter { $0.pathExtension == "appex" }.compactMap { appex in
            guard let data = try? Data(contentsOf: appex.appendingPathComponent("Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let ext = info["NSExtension"] as? [String: Any] else { return nil }
            return ext["NSExtensionPointIdentifier"] as? String
        })
    }

    /// Device builds carry entitlements in the code signature. Simulator builds
    /// are ad-hoc signed with none there; Xcode embeds them in the binary's
    /// `__TEXT,__entitlements` section instead. Read both and merge.
    static func readEntitlements(app: URL, binary: URL) async -> Set<String> {
        var keys = Set<String>()
        if let signed = try? await Shell.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path], check: false),
           let dict = plistDict(signed.stdout) {
            keys.formUnion(dict.keys)
        }
        if let section = try? await Shell.xcrun("otool", "-X", "-s", "__TEXT", "__entitlements", binary.path, check: false),
           let dict = plistDict(decodeOtoolHex(section.text)) {
            keys.formUnion(dict.keys)
        }
        return keys
    }

    /// `otool -X -s` prints `address word word word word`, each word a
    /// little-endian 32-bit value. Turn it back into bytes.
    static func decodeOtoolHex(_ text: String) -> Data {
        var bytes = [UInt8]()
        for line in text.split(separator: "\n") {
            for word in line.split(whereSeparator: \.isWhitespace).dropFirst() {
                guard word.count % 2 == 0, let value = UInt64(word, radix: 16) else { continue }
                let count = word.count / 2
                for i in 0..<count { bytes.append(UInt8((value >> (8 * UInt64(i))) & 0xFF)) }
            }
        }
        while bytes.last == 0 { bytes.removeLast() }
        return Data(bytes)
    }

    static func plistDict(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let start = data.firstRange(of: Data("<?xml".utf8)) ?? data.firstRange(of: Data("<plist".utf8)) else { return nil }
        let slice = data[start.lowerBound...]
        return (try? PropertyListSerialization.propertyList(from: Data(slice), format: nil)) as? [String: Any]
    }

    /// System frameworks linked by the main binary, its `.debug.dylib` (Xcode
    /// debug builds), and every embedded framework or dylib.
    static func linkedFrameworks(app: URL, executable: String) async -> Set<String> {
        var binaries = [app.appendingPathComponent(executable),
                        app.appendingPathComponent("\(executable).debug.dylib")]
        let frameworksDir = app.appendingPathComponent("Frameworks")
        for item in (try? FileManager.default.contentsOfDirectory(at: frameworksDir, includingPropertiesForKeys: nil)) ?? [] {
            switch item.pathExtension {
            case "framework": binaries.append(item.appendingPathComponent(item.deletingPathExtension().lastPathComponent))
            case "dylib": binaries.append(item)
            default: break
            }
        }
        let existing = binaries.filter { FileManager.default.fileExists(atPath: $0.path) }
        return await withTaskGroup(of: Set<String>.self) { group in
            for binary in existing {
                group.addTask {
                    guard let out = try? await Shell.xcrun("otool", "-L", binary.path, check: false) else { return [] }
                    return parseFrameworks(out.text)
                }
            }
            var all = Set<String>()
            for await set in group { all.formUnion(set) }
            return all
        }
    }

    static func parseFrameworks(_ otool: String) -> Set<String> {
        var set = Set<String>()
        for line in otool.split(separator: "\n") {
            guard let range = line.range(of: "/System/Library/Frameworks/") else { continue }
            let rest = line[range.upperBound...]
            if let end = rest.range(of: ".framework/") { set.insert(String(rest[..<end.lowerBound])) }
        }
        return set
    }
}
