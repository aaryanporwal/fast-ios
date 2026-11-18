import Foundation
import Synchronization
import Testing
@testable import FastIOSCore

@Suite("Disabled store: the launchd overrides file")
struct DisabledStoreTests {
    @Test("A simulator that never booted has an empty store, not an error")
    func missingStoreIsEmpty() throws {
        let udid = TestEnv.fakeUDID()
        #expect(try DisabledStore.read(udid) == [:])
        #expect(DisabledStore.disabledLabels(udid).isEmpty)
    }

    @Test("write then read returns every entry, false ones too")
    func roundTrip() throws {
        let udid = TestEnv.fakeUDID()
        defer { TestEnv.cleanUp(udid) }
        let entries = ["com.apple.assetsd": true, "com.apple.contactsd": true, "com.apple.runtime.own": false]
        try DisabledStore.write(udid, entries)
        #expect(try DisabledStore.read(udid) == entries)
        #expect(DisabledStore.disabledLabels(udid) == ["com.apple.assetsd", "com.apple.contactsd"])
    }

    @Test("write leaves no temp file and sets mode 0644")
    func writeIsClean() throws {
        let udid = TestEnv.fakeUDID()
        defer { TestEnv.cleanUp(udid) }
        try DisabledStore.write(udid, ["a": true])
        try DisabledStore.write(udid, ["b": true])
        let files = try FileManager.default.contentsOfDirectory(atPath: DisabledStore.folder(udid).path)
        #expect(files == ["disabled.plist"])
        let mode = try FileManager.default.attributesOfItem(atPath: DisabledStore.path(udid).path)[.posixPermissions] as? Int
        #expect(mode == 0o644)
    }

    @Test("Concurrent writers never expose a half-written file to a reader")
    func atomicUnderConcurrency() async throws {
        let udid = TestEnv.fakeUDID()
        defer { TestEnv.cleanUp(udid) }
        // Large enough that a non-atomic write would be caught mid-way.
        let entries: @Sendable (Int) -> [String: Bool] = { n in
            Dictionary(uniqueKeysWithValues: (0..<400).map { ("com.example.writer\(n).label\($0)", true) })
        }
        try DisabledStore.write(udid, entries(0))
        // A Sendable class owns the atomics: Swift 6.3 rejects local
        // non-copyable Atomics captured by `sending` task closures.
        final class Counters: Sendable {
            let bad = Atomic<Int>(0)
            let done = Atomic<Bool>(false)
        }
        let c = Counters()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while !c.done.load(ordering: .relaxed) {
                    do {
                        let read = try DisabledStore.read(udid)
                        if read.count != 400 { c.bad.add(1, ordering: .relaxed) }
                    } catch { c.bad.add(1, ordering: .relaxed) }
                    // Yield, so the writers run even when this is the only
                    // free thread (CI runners have few; without this the
                    // reader spun forever and the suite hung).
                    await Task.yield()
                }
            }
            await withTaskGroup(of: Void.self) { writers in
                for w in 1...6 {
                    writers.addTask { for _ in 0..<40 { try? DisabledStore.write(udid, entries(w)) } }
                }
            }
            c.done.store(true, ordering: .relaxed)
        }
        #expect(c.bad.load(ordering: .relaxed) == 0)
        #expect(try DisabledStore.read(udid).count == 400)
    }

    @Test("apply disables, re-enables, and never touches labels it does not manage")
    func applyChangesOnlyManagedLabels() throws {
        let udid = TestEnv.fakeUDID()
        defer { TestEnv.cleanUp(udid) }
        let managed: Set<String> = ["com.apple.assetsd", "com.apple.contactsd", "com.apple.healthd"]
        try DisabledStore.write(udid, ["com.apple.healthd": true, "com.vendor.other": true, "com.apple.own": false])

        let change = try DisabledStore.apply(udid, disable: ["com.apple.assetsd", "com.apple.contactsd", "not.managed"],
                                             managed: managed)
        #expect(change.disabled == ["com.apple.assetsd", "com.apple.contactsd"])
        #expect(change.reenabled == ["com.apple.healthd"])
        let after = try DisabledStore.read(udid)
        #expect(after == ["com.apple.assetsd": true, "com.apple.contactsd": true,
                          "com.vendor.other": true, "com.apple.own": false])
    }

    @Test("apply writes nothing when nothing changes")
    func applyIsIdempotent() throws {
        let udid = TestEnv.fakeUDID()
        defer { TestEnv.cleanUp(udid) }
        let managed: Set<String> = ["com.apple.assetsd"]
        try DisabledStore.apply(udid, disable: ["com.apple.assetsd"], managed: managed)
        let path = DisabledStore.path(udid).path
        let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        let inode = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int
        Thread.sleep(forTimeInterval: 0.05)
        let change = try DisabledStore.apply(udid, disable: ["com.apple.assetsd"], managed: managed)
        #expect(change.isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date == before)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int == inode)
    }
}
