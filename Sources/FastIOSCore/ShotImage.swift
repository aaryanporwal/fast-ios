import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shrinks a screenshot for agents: a full iPhone 18 Pro PNG is 1206×2622
/// pixels, far more than a model needs to read a screen.
enum ShotImage {
    struct Size: Sendable, Equatable {
        let width: Int
        let height: Int
        let bytes: Int
    }

    /// The width to scale to, or nil to keep the image as it is. Never
    /// enlarges; `scale` and `maxWidth` together take the smaller result.
    static func targetWidth(width: Int, maxWidth: Int?, scale: Double?) -> Int? {
        var target = width
        if let maxWidth, maxWidth > 0 { target = min(target, maxWidth) }
        if let scale, scale > 0, scale < 1 { target = min(target, Int((Double(width) * scale).rounded())) }
        return target < width ? max(target, 1) : nil
    }

    /// Scales `png` in place if asked, and returns its final size.
    static func finish(_ png: URL, maxWidth: Int?, scale: Double?) throws -> Size {
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            throw ShotError(message: "Cannot read the screenshot \(png.path).")
        }
        if let target = targetWidth(width: width, maxWidth: maxWidth, scale: scale) {
            let targetHeight = max(1, Int((Double(height) * Double(target) / Double(width)).rounded()))
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(target, targetHeight),
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw ShotError(message: "Cannot scale the screenshot \(png.path).")
            }
            let temp = png.deletingLastPathComponent().appendingPathComponent(".\(png.lastPathComponent).scaled")
            guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ShotError(message: "Cannot write \(temp.path).")
            }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { throw ShotError(message: "Cannot write \(temp.path).") }
            guard rename(temp.path, png.path) == 0 else { throw ShotError(message: "Cannot replace \(png.path).") }
            return try size(png, width: image.width, height: image.height)
        }
        return try size(png, width: width, height: height)
    }

    static func size(_ png: URL, width: Int, height: Int) throws -> Size {
        let bytes = try FileManager.default.attributesOfItem(atPath: png.path)[.size] as? Int ?? 0
        return Size(width: width, height: height, bytes: bytes)
    }
}
