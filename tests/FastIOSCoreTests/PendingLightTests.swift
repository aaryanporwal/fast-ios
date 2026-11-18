import Foundation
import Testing
@testable import FastIOSCore

@Suite("Pending light: simulators running at `fast-ios on`", .serialized)
struct PendingLightTests {
    static func device(_ udid: String, _ state: String) -> SimDevice {
        SimDevice(udid: udid, name: udid, state: state, isAvailable: true,
                  runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", deviceTypeIdentifier: nil)
    }

    @Test("A pending simulator becomes light once stopped; running ones wait; gone ones are forgotten")
    func appliesWhenStopped() throws {
        TestEnv.ready()
        PendingLight.clear()
        let stopped = UUID().uuidString, running = UUID().uuidString, gone = UUID().uuidString
        try PendingLight.add([stopped, running, gone])
        defer {
            try? FileManager.default.removeItem(at: DisabledStore.folder(stopped))
            PendingLight.clear()
        }
        let made = PendingLight.applyStopped(
            devices: [Self.device(stopped, "Shutdown"), Self.device(running, "Booted")],
            profile: Profiler.full(), log: { _ in })
        #expect(made == [stopped])
        #expect(PendingLight.load() == [running])
        #expect(!DisabledStore.disabledLabels(stopped).intersection(ServiceCatalog.slimmable).isEmpty)
        #expect(StateStore.load().devices[stopped] != nil)
    }

    @Test("Clearing empties the list")
    func clears() throws {
        TestEnv.ready()
        try PendingLight.add(["A"])
        PendingLight.clear()
        #expect(PendingLight.load().isEmpty)
    }
}
