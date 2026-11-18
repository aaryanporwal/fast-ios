import Foundation
import Testing
@testable import FastIOSCore

/// Small decisions that, if wrong, reboot a simulator for nothing, report a
/// slim simulator as stock, reinstall every time, or garble the tree agents read.
@Suite("Reboot, verify, install and tree decisions")
struct DecisionTests {
    @Test("slim reboots a booted simulator only when the store would change")
    func pendingChange() throws {
        let udid = TestEnv.fakeUDID()
        defer { TestEnv.cleanUp(udid) }
        let want: Set<String> = ["com.apple.assetsd", "com.apple.contactsd"]
        #expect(try Slimmer.pendingChange(udid, disable: want), "empty store: change pending")
        try DisabledStore.apply(udid, disable: want)
        #expect(try Slimmer.pendingChange(udid, disable: want) == false, "already applied: no reboot")
        #expect(try Slimmer.pendingChange(udid, disable: ["com.apple.assetsd"]), "contactsd must be re-enabled")
        #expect(try Slimmer.pendingChange(udid, disable: want.union(["com.apple.backboardd"])) == false,
                "a protected label in the request is dropped, not a change")
    }

    @Test("launchctl print-disabled output is parsed in both runtime formats")
    func parseDisabled() {
        let out = """
        disabled services = {
        	"com.apple.assetsd" => disabled
        	"com.apple.contactsd" => true
        	"com.apple.backboardd" => enabled
        	"com.apple.healthd" => false
        }
        """
        #expect(Simctl.parseDisabled(out) == ["com.apple.assetsd", "com.apple.contactsd"])
        #expect(Simctl.parseDisabled("").isEmpty)
    }

    @Test("Runtime identifiers read as names")
    func runtimeName() {
        #expect(TestEnv.device().runtimeName == "iOS 27.0")
    }

    @Test("otool -X hex words decode back to the entitlements plist bytes")
    func otoolHex() {
        // "<?xml" = 3c 3f 78 6d 6c, little-endian 32-bit words, trailing zero padding dropped.
        let text = "0000000100004000\t6d783f3c 0000006c\n"
        #expect(AppInspector.decodeOtoolHex(text) == Data("<?xml".utf8))
    }

    @Test("The install fingerprint changes when a file changes, not when nothing does")
    func fingerprint() throws {
        let dir = TestEnv.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("A.app"), b = dir.appendingPathComponent("B.app")
        try FileManager.default.copyItem(at: TestEnv.fixture("Sample.app"), to: a)
        try FileManager.default.copyItem(at: a, to: b) // copyItem keeps modification dates, like simctl install
        #expect(Shot.fingerprint(a) == Shot.fingerprint(b))
        #expect(Shot.fingerprint(a).keys.contains("/PlugIns/Widget.appex/Info.plist"))
        try Data("rebuilt".utf8).write(to: b.appendingPathComponent("Sample"))
        #expect(Shot.fingerprint(a) != Shot.fingerprint(b))
    }

    @Test("The compact tree drops bare containers and keeps every labelled element")
    func compactTree() {
        let leaf = AXNode(type: "StaticText", frame: [10, 20, 100.4, 30.6], label: "Say \"hi\"")
        let button = AXNode(type: "Button", frame: [0, 0, 44, 44], label: "Done", id: "done", enabled: false, selected: true)
        let field = AXNode(type: "TextField", frame: [0, 50, 200, 30], value: "abc", placeholder: "Name", focused: true)
        let bare = AXNode(type: "Other", frame: [0, 0, 402, 874], children: [leaf, button])
        let root = AXNode(type: "Application", frame: [0, 0, 402, 874], label: "App",
                          children: [AXNode(type: "Window", frame: [0, 0, 402, 874], children: [bare, field])])
        #expect(ShotTree.compact(root) == """
        Application "App" [0,0,402,874]
          Window [0,0,402,874]
            StaticText "Say \\"hi\\"" [10,20,100,31]
            Button "Done" id=done disabled selected [0,0,44,44]
            TextField value="abc" placeholder="Name" focused [0,50,200,30]
        """)
        #expect(root.count == 6)
    }
}
