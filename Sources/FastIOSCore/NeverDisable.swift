/// Labels fast-ios never disables, whatever a profile or `--disable` asks.
/// Disabling these deadlocks boot, hangs app launch, or breaks basic system UI.
/// The first three rows are simslim's AlwaysEnabled list, copied as-is.
public enum NeverDisable {
    public static let labels: [String: String] = [
        "com.apple.assistantd": "Hosts the dictation service; without it the system Spotlight app leaks memory. (simslim)",
        "com.apple.gamed": "Required for timely XCUITest app launches (DTServiceHub / GameKit). (simslim)",
        "com.apple.sharingd": "Required for system share sheets. (simslim)",
        "com.apple.backboardd": "Owns the display and touch input; the simulator never finishes booting without it.",
        "com.apple.SpringBoard": "The Home Screen and app launcher.",
        "com.apple.locationd": "Location services; apps that ask for location block on it.",
        "com.apple.securityd": "Keychain and certificate trust; most networking blocks on it.",
        "com.apple.trustd": "Certificate trust evaluation for every TLS connection.",
        "com.apple.runningboardd": "Process lifecycle for every app; app launch hangs without it.",
        "com.apple.frontboard.systemappservices": "App scene management used by SpringBoard.",
        "com.apple.lsd": "Launch Services: app registration and URL routing.",
        "com.apple.mobile.installd": "Installs apps; `simctl install` fails without it.",
        "com.apple.containermanagerd": "App data containers; app launch fails without it.",
        "com.apple.cfprefsd.xpc.daemon": "User defaults for every process.",
        "com.apple.tccd": "Privacy permission prompts and their stored answers.",
        "com.apple.mediaserverd": "Audio and video playback and capture.",
        "com.apple.dasd": "Background task scheduling (BGTaskScheduler).",
        "com.apple.notifyd": "Darwin notifications used across the system.",
        "com.apple.logd": "Unified logging; Xcode's console reads from it.",
        "com.apple.configd": "Network configuration and reachability.",
        "com.apple.CoreSimulator.bridge": "The host-to-simulator bridge that simctl uses.",
        "com.apple.UserEventAgent-System": "Delivers system events that launch other daemons.",
    ]

    public static func isProtected(_ label: String) -> Bool { labels[label] != nil }
}
