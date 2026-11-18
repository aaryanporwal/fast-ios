import AppKit
import CoreGraphics

// render.swift <sheet.png> <outdir>: app icon set + menu-bar template from the
// forward-facing centre cell of page-mascot's tiger-directions sheet.
let args = CommandLine.arguments
let sheet = NSImage(contentsOfFile: args[1])!
var rect = CGRect(x: 0, y: 0, width: sheet.size.width, height: sheet.size.height)
let cg = sheet.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
let cell = cg.width / 3
// Centre cell, then the tight box of non-transparent pixels.
let centre = cg.cropping(to: CGRect(x: cell, y: cell, width: cell, height: cell))!
func bounds(_ img: CGImage) -> CGRect {
    let w = img.width, h = img.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h { for x in 0..<w where data[(y * w + x) * 4 + 3] > 40 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
    // Row 0 of the buffer is the top row of the image, as cropping expects.
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}
let tiger = centre.cropping(to: bounds(centre))!
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir.appendingPathComponent("AppIcon.iconset"), withIntermediateDirectories: true)

func png(_ size: Int, _ draw: (CGContext, CGFloat) -> Void) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    draw(ctx, CGFloat(size))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

/// Apple's macOS grid: an 824/1024 rounded square, centred, with a soft shadow.
func icon(_ ctx: CGContext, _ s: CGFloat) {
    let inset = s * 100 / 1024
    let box = CGRect(x: inset, y: inset + s * 0.012, width: s - 2 * inset, height: s - 2 * inset)
    let shape = CGPath(roundedRect: box, cornerWidth: box.width * 0.225, cornerHeight: box.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(shape); ctx.setFillColor(CGColor(srgbRed: 0.105, green: 0.235, blue: 0.215, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    // The tiger fills most of the width; its chest runs off the bottom edge.
    // The shape clips the chest, which fades out in the source art.
    let w = box.width * 0.86
    let h = w * CGFloat(tiger.height) / CGFloat(tiger.width)
    ctx.draw(tiger, in: CGRect(x: box.midX - w / 2, y: box.minY - h * 0.2, width: w, height: h))
    ctx.restoreGState()
    // A hairline edge so the shape holds on dark Docks.
    ctx.addPath(shape); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(max(1, s / 512)); ctx.strokePath()
}

for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! png(size, icon).write(to: outDir.appendingPathComponent("AppIcon.iconset/icon_\(name).png"))
}

/// Menu-bar template: the tiger's dark line work (outline, stripes, eyes)
/// as opaque black, its fills transparent.
func template(_ ctx: CGContext, _ s: CGFloat) {
    let w = tiger.width, h = tiger.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let src = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    src.draw(tiger, in: CGRect(x: 0, y: 0, width: w, height: h))
    for i in stride(from: 0, to: data.count, by: 4) {
        let a = Double(data[i + 3]) / 255
        guard a > 0 else { continue }
        let lum = (0.3 * Double(data[i]) + 0.59 * Double(data[i + 1]) + 0.11 * Double(data[i + 2])) / 255 / a
        let ink = lum < 0.42 ? 1.0 : 0.0
        data[i] = 0; data[i + 1] = 0; data[i + 2] = 0; data[i + 3] = UInt8(ink * a * 255)
    }
    let lines = src.makeImage()!.cropping(to: CGRect(x: 0, y: 0, width: w, height: Int(Double(h) * 0.8)))!
    let scale = s / CGFloat(max(lines.width, lines.height))
    let dw = CGFloat(lines.width) * scale, dh = CGFloat(lines.height) * scale
    ctx.draw(lines, in: CGRect(x: (s - dw) / 2, y: (s - dh) / 2, width: dw, height: dh))
}
try! png(18, template).write(to: outDir.appendingPathComponent("MenuBarIcon.png"))
try! png(36, template).write(to: outDir.appendingPathComponent("MenuBarIcon@2x.png"))
try! png(512, template).write(to: outDir.appendingPathComponent("MenuBarIcon-preview.png"))
print("tiger \(tiger.width)x\(tiger.height)")
