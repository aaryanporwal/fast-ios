import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FastIOSCore

@Suite("Shot downscaling, runner session plumbing and --grant")
struct ShotAndGrantTests {
    static func writePNG(width: Int, height: Int, to url: URL) throws {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 0.1, green: 0.6, blue: 0.3, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test("The target width never enlarges and takes the smaller of max-width and scale")
    func targetWidth() {
        #expect(ShotImage.targetWidth(width: 1206, maxWidth: nil, scale: nil) == nil)
        #expect(ShotImage.targetWidth(width: 1206, maxWidth: 400, scale: nil) == 400)
        #expect(ShotImage.targetWidth(width: 1206, maxWidth: 2000, scale: nil) == nil)
        #expect(ShotImage.targetWidth(width: 1206, maxWidth: nil, scale: 0.5) == 603)
        #expect(ShotImage.targetWidth(width: 1206, maxWidth: 400, scale: 0.5) == 400)
        #expect(ShotImage.targetWidth(width: 1206, maxWidth: nil, scale: 1) == nil)
    }

    @Test("finish scales the PNG in place, keeps the aspect ratio and reports bytes")
    func finishScales() throws {
        let dir = TestEnv.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("s.png")
        try Self.writePNG(width: 1206, height: 2622, to: png)
        let full = try ShotImage.finish(png, maxWidth: nil, scale: nil)
        #expect(full.width == 1206 && full.height == 2622)
        let small = try ShotImage.finish(png, maxWidth: 400, scale: nil)
        #expect(small.width == 400)
        #expect(abs(small.height - 870) <= 1)
        #expect(small.bytes > 0 && small.bytes < full.bytes)
        #expect(small.bytes == (try FileManager.default.attributesOfItem(atPath: png.path)[.size] as? Int))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files == ["s.png"], "no temp file is left behind")
    }

    @Test("--grant accepts simctl services, rejects known gaps with the reason")
    func grantValidation() throws {
        #expect(try Privacy.validate(["Photos", "location", "photos"]) == ["photos", "location"])
        #expect(try Privacy.validate([]) == [])
        #expect(try Privacy.validate(["all"]) == ["all"])
        do {
            _ = try Privacy.validate(["notifications"])
            Issue.record("notifications must be rejected")
        } catch let e as InvalidArguments {
            #expect(e.message.contains("no notifications service"))
        }
        #expect(throws: InvalidArguments.self) { try Privacy.validate(["telepathy"]) }
        #expect(Set(Privacy.services.keys).isDisjoint(with: Privacy.notCovered.keys))
    }

    @Test("all expands to one grant per service, because simctl's own all row is ignored by apps")
    func allExpands() {
        #expect(!Privacy.expand(["all"]).contains("all"))
        #expect(Privacy.expand(["all"]).contains("photos"))
        #expect(Privacy.expand(["photos", "all"]).filter { $0 == "photos" }.count == 1)
        #expect(Privacy.expand(["photos-add"]) == ["photos-add"])
        #expect(Set(Privacy.allExpanded).isSubset(of: Privacy.services.keys))
    }

    @Test("shot and run reject a permission simctl cannot grant before doing anything")
    func toolsValidateGrant() async {
        let shot = MCPTools.named("shot")!
        let run = MCPTools.named("run")!
        await #expect(throws: InvalidArguments.self) { _ = try await shot.call(["app": "/nope.app", "grant": ["camera"]]) }
        await #expect(throws: InvalidArguments.self) { _ = try await run.call(["app": "/nope.app", "grant": ["notifications"]]) }
    }

    @Test("CLI words map --scale, --max-width and repeated --grant")
    func cliMapping() throws {
        let args = try MCPTools.named("shot")!.cliArguments(
            ["--app", "A.app", "--scale", "0.5", "--max-width", "400", "--grant", "photos", "--grant", "location", "--no-session"])
        #expect(args["scale"] == .double(0.5))
        #expect(args["maxWidth"] == .int(400))
        #expect(args["grant"] == ["photos", "location"])
        #expect(args["noSession"] == true)
        #expect(throws: UsageError.self) { _ = try MCPTools.named("shot")!.cliArguments(["--scale", "half"]) }
    }

    @Test("A session folder with no live process is not live")
    func sessionLiveness() throws {
        let udid = "SESSION-TEST-\(UUID().uuidString)"
        let dir = ShotSession.folder(udid)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!ShotSession.isLive(udid: udid))
        // A dead pid with a heartbeat is still not live.
        let info = ShotSession.Info(pid: 999_999, startTime: 1, xctestrun: "/x")
        try JSONEncoder().encode(info).write(to: dir.appendingPathComponent("session.json"))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("heartbeat").path, contents: Data("1".utf8))
        #expect(!ShotSession.isLive(udid: udid))
        // This test process, with its real start time, counts as alive.
        let me = ProcessRef.current
        try JSONEncoder().encode(ShotSession.Info(pid: me.pid, startTime: me.startTime, xctestrun: "/x"))
            .write(to: dir.appendingPathComponent("session.json"))
        #expect(ShotSession.isLive(udid: udid))
    }

    @Test("The runner template keeps both tests and the request protocol")
    func runnerTemplate() {
        let src = ShotRunnerTemplates.testSource
        #expect(src.contains("func testSnapshot()"))
        #expect(src.contains("func testSession()"))
        #expect(src.contains("FASTIOS_SESSION_DIR"))
        #expect(src.contains("hasPrefix(\"req-\")"))
    }
}
