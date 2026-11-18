// A tiny iOS app that reports, without asking, the authorization status of
// each permission an app can prompt for, and writes it to
// Documents/privacy.json. scripts/privacy-probe/run.sh uses it to see which
// prompts `simctl privacy grant` answers in advance. Status 0 everywhere
// below means "not determined": the app would still show a prompt.
import AVFoundation
import AppTrackingTransparency
import Contacts
import CoreBluetooth
import CoreLocation
import CoreMotion
import EventKit
import MediaPlayer
import Photos
import Speech
import SwiftUI
import UserNotifications

@main
struct ProbeApp: App {
    init() {
        Task { await Self.report() }
    }

    var body: some Scene {
        WindowGroup { Text("privacy probe") }
    }

    static func report() async {
        NSLog("probe: start")
        let mic = AVAudioApplication.shared.recordPermission
        var status: [String: Int] = [
            "photos": PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue,
            "photos-add": PHPhotoLibrary.authorizationStatus(for: .addOnly).rawValue,
            "contacts": CNContactStore.authorizationStatus(for: .contacts).rawValue,
            "calendar": EKEventStore.authorizationStatus(for: .event).rawValue,
            "reminders": EKEventStore.authorizationStatus(for: .reminder).rawValue,
            "location": Int(CLLocationManager().authorizationStatus.rawValue),
            "microphone": mic == .undetermined ? 0 : (mic == .granted ? 3 : 2),
            "camera": AVCaptureDevice.authorizationStatus(for: .video).rawValue,
            "media-library": MPMediaLibrary.authorizationStatus().rawValue,
            "motion": CMMotionActivityManager.authorizationStatus().rawValue,
            "speech": SFSpeechRecognizer.authorizationStatus().rawValue,
            "tracking": Int(ATTrackingManager.trackingAuthorizationStatus.rawValue),
            "bluetooth": CBManager.authorization.rawValue,
        ]
        NSLog("probe: statuses read")
        // notificationSettings() did not return on iOS 27.0 in this probe;
        // ask with the callback API and give up after 5 s (-1 = no answer).
        let box = NotificationBox()
        UNUserNotificationCenter.current().getNotificationSettings { box.set($0.authorizationStatus.rawValue) }
        for _ in 0..<50 where box.value == nil { try? await Task.sleep(for: .milliseconds(100)) }
        status["notifications"] = box.value ?? -1
        NSLog("probe: notifications \(status["notifications"] ?? -2)")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) {
            try? data.write(to: docs.appendingPathComponent("privacy.json"))
        }
    }
}

final class NotificationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?
    var value: Int? { lock.withLock { stored } }
    func set(_ v: Int) { lock.withLock { stored = v } }
}
