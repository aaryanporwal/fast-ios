import Foundation
@testable import FastIOSCore

/// Every test that reads or writes fast-ios state calls `TestEnv.ready()`
/// first: it points `FASTIOS_STATE_DIR` at a fresh temp folder (once per test
/// process), so no test ever touches ~/Library/Application Support/fast-ios.
enum TestEnv {
    private static let stateDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fast-ios-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FASTIOS_STATE_DIR", dir.path, 1)
        unsetenv("FASTIOS_DEVICE_SET")
        return dir
    }()

    @discardableResult
    static func ready() -> URL {
        let dir = stateDir
        precondition(StateStore.url.deletingLastPathComponent().path == dir.path,
                     "tests must never write the real state folder")
        return dir
    }

    static func fixture(_ name: String) -> URL {
        guard let root = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            fatalError("Fixtures folder missing from the test bundle")
        }
        return root.appendingPathComponent(name)
    }

    /// A UDID no real simulator has; its DisabledStore folder is removed by `cleanUp`.
    static func fakeUDID() -> String { "FASTIOS-TEST-\(UUID().uuidString)" }

    static func cleanUp(_ udid: String) {
        try? FileManager.default.removeItem(at: DisabledStore.folder(udid))
    }

    static func temp(_ name: String = UUID().uuidString) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fast-ios-test-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func device(_ udid: String = "00000000-0000-0000-0000-000000000001", state: String = "Booted") -> SimDevice {
        SimDevice(udid: udid, name: "Test iPhone", state: state, isAvailable: true,
                  runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                  deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro")
    }
}
