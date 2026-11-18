import Foundation

/// `--grant`: answers permission prompts before the app starts, with
/// `xcrun simctl privacy <udid> grant <service> <bundle id>`, so an agent's
/// first screenshot is the app and not a system alert.
public enum Privacy {
    /// What `simctl privacy` grants on Xcode 27.2 (`xcrun simctl help privacy`).
    /// "all" grants every one of them.
    public static let services: [String: String] = [
        "all": "every service below",
        "calendar": "Calendar (EventKit events)",
        "contacts": "Contacts, full access",
        "contacts-limited": "Contacts, basic info only",
        "location": "Location while the app is in use",
        "location-always": "Location at all times",
        "photos": "Photo library, full access (iOS 26.5 ignored this grant in the probe; iOS 27.0 honours it)",
        "photos-add": "Adding to the photo library",
        "media-library": "Apple Music and media library",
        "microphone": "Microphone",
        "motion": "Motion and fitness",
        "reminders": "Reminders",
        "siri": "Siri",
    ]

    /// Prompts `simctl privacy` cannot answer, measured on iOS 27.0 with
    /// scripts/privacy-probe: each stayed undetermined after every grant.
    public static let notCovered: [String: String] = [
        "notifications": "simctl privacy has no notifications service; the app still asks. In UI tests, tap Allow on the alert, or have the app skip the request in test builds.",
        "camera": "simctl privacy has no camera service; the app still asks (and the simulator has no camera).",
        "speech": "simctl privacy has no speech-recognition service; the app still asks.",
        "tracking": "simctl privacy has no App Tracking Transparency service; the app still asks.",
        "bluetooth": "nothing to grant: the simulator already reports Bluetooth as allowed, so no prompt appears.",
    ]

    /// Checks names before anything runs; returns them lowercased, in order,
    /// without duplicates.
    public static func validate(_ names: [String]) throws -> [String] {
        var out: [String] = []
        for raw in names {
            let name = raw.lowercased()
            if services[name] != nil {
                if !out.contains(name) { out.append(name) }
            } else if let why = notCovered[name] {
                throw InvalidArguments("--grant \(name): \(why)")
            } else {
                throw InvalidArguments("--grant \(raw) is not a permission simctl privacy knows. Use one of: \(services.keys.sorted().joined(separator: ", ")).")
            }
        }
        return out
    }

    /// What "all" expands to. `simctl privacy grant all` itself writes one
    /// kTCCServiceAll row that apps do not honour (measured on iOS 27.0:
    /// photos, contacts, calendar and the rest stayed undetermined), so
    /// fast-ios grants each service on its own.
    public static let allExpanded = ["calendar", "contacts", "location", "photos", "media-library",
                                     "microphone", "motion", "reminders", "siri"]

    /// The simctl services `names` resolves to, "all" expanded.
    public static func expand(_ names: [String]) -> [String] {
        var out: [String] = []
        for n in names.flatMap({ $0 == "all" ? allExpanded : [$0] }) where !out.contains(n) { out.append(n) }
        return out
    }

    /// Grants each service to the app, one simctl call per service. Do it
    /// before launch: iOS terminates a running app for some changes.
    public static func grant(_ names: [String], bundleID: String, udid: String) async throws {
        for name in expand(names) {
            try await Simctl.simctl("privacy", udid, "grant", name, bundleID)
        }
    }

    /// One line for help texts.
    public static var helpLine: String {
        "Grantable: \(services.keys.filter { $0 != "all" }.sorted().joined(separator: ", ")), or all. Not grantable (the app still asks): notifications, camera, speech, tracking. Bluetooth needs no grant on the simulator."
    }
}
