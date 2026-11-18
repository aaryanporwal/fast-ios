import CoreGraphics
import Foundation
import ImageIO

/// A screenshot reduced to a small RGBA grid, to tell "a spinner turned"
/// from "the screen changed".
struct ScreenPixels: Sendable {
    /// Share of the screen that may change while it still counts as settled.
    static let smallChange = 0.01
    static let width = 200

    let pixels: [UInt8]
    let height: Int

    init?(png: URL) {
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0 else { return nil }
        let w = Self.width
        let h = max(1, image.height * w / image.width)
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        pixels = buffer
        height = h
    }

    /// Share of grid cells whose colour moved by more than a small tolerance.
    func changedFraction(from other: ScreenPixels) -> Double {
        guard other.height == height, other.pixels.count == pixels.count else { return 1 }
        var changed = 0
        var i = 0
        while i < pixels.count {
            let d = abs(Int(pixels[i]) - Int(other.pixels[i])) + abs(Int(pixels[i + 1]) - Int(other.pixels[i + 1]))
                + abs(Int(pixels[i + 2]) - Int(other.pixels[i + 2]))
            if d > 24 { changed += 1 }
            i += 4
        }
        return Double(changed) / Double(pixels.count / 4)
    }
}
