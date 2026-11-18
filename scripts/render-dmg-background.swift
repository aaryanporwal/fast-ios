import AppKit

// render-dmg-background.swift <out-dir>: the drag-to-Applications window
// background, 640x400 points, at 1x and 2x.
let out = URL(fileURLWithPath: CommandLine.arguments[1])

func render(scale: CGFloat) -> Data {
    let size = NSSize(width: 640 * scale, height: 400 * scale)
    let image = NSImage(size: size, flipped: true) { rect in
        NSColor(srgbRed: 0.965, green: 0.961, blue: 0.949, alpha: 1).setFill()
        rect.fill()
        func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat, width: CGFloat = 520) {
            let style = NSMutableParagraphStyle(); style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * scale, weight: weight),
                                                        .foregroundColor: color, .paragraphStyle: style]
            let w = width * scale
            NSString(string: s).draw(in: NSRect(x: (rect.width - w) / 2, y: y * scale, width: w, height: 80 * scale), withAttributes: attrs)
        }
        text("Drag fast-ios to Applications", size: 22, weight: .semibold, color: NSColor(white: 0.12, alpha: 1), y: 44)
        text("Then open it from Applications. It lives in the menu bar.", size: 13, weight: .regular, color: NSColor(white: 0.4, alpha: 1), y: 78)
        // Arrow between the app (x 160) and Applications (x 480), at icon height (y 205).
        let arrow = NSBezierPath()
        arrow.lineWidth = 3 * scale
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        let y = 205 * scale
        arrow.move(to: NSPoint(x: 262 * scale, y: y)); arrow.line(to: NSPoint(x: 378 * scale, y: y))
        arrow.move(to: NSPoint(x: 364 * scale, y: y - 12 * scale)); arrow.line(to: NSPoint(x: 380 * scale, y: y)); arrow.line(to: NSPoint(x: 364 * scale, y: y + 12 * scale))
        NSColor(srgbRed: 0.85, green: 0.45, blue: 0.13, alpha: 1).setStroke()
        arrow.stroke()
        text("If macOS says it cannot check fast-ios: open System Settings > Privacy & Security, scroll down and click Open Anyway.",
             size: 11, weight: .regular, color: NSColor(white: 0.45, alpha: 1), y: 336, width: 470)
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
try! render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try! render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
