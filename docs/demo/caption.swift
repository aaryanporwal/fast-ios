// Renders one caption line as a PNG strip for the demo video:
//   swift docs/demo/caption.swift "<text>" <width> <out.png>
// White, large, on a nearly opaque black band, so it reads on any frame.
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let width = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: caption.swift <text> <width> <out.png>\n".utf8)); exit(64)
}
let text = args[1], out = args[3]
let height = 92.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(calibratedWhite: 0, alpha: 0.86).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
let style = NSMutableParagraphStyle()
style.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 40, weight: .semibold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: style,
]
let size = (text as NSString).size(withAttributes: attrs)
(text as NSString).draw(in: NSRect(x: 0, y: (height - size.height) / 2, width: width, height: size.height), withAttributes: attrs)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
