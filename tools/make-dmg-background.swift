// Draws the background of the app's disk image: where to drag the app, and what to do the
// first time macOS asks about it (the app is signed ad hoc, not notarized).
// Usage: swift tools/make-dmg-background.swift <output.png> <scale> <App Name> [hex1 hex2 hex3]
//   scale: 1 or 2 (Retina). Colors: a gradient from the top left, dark enough for white text;
//   by default RandAmp's: 5A2A3E 2E1A4A 15102C. Pick them from the app icon.
import AppKit

let args = CommandLine.arguments
let output = args.count > 1 ? args[1] : "background.png"
let scale = CGFloat(args.count > 2 ? Double(args[2]) ?? 1 : 1)
let appName = args.count > 3 ? args[3] : "the app"
let hexes = args.count > 6 ? Array(args[4...6]) : ["5A2A3E", "2E1A4A", "15102C"]
// The window shows 660 x 380 points; the icons sit at y = 150 (from the top) in tools/dmg-settings.py.
// Kept short, so a Finder showing its path and status bars doesn't cut the bottom off.
let width: CGFloat = 660, height: CGFloat = 380

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Background: the icon's gradient, darkened so the icons and the text stand out.
let gradient = NSGradient(colors: hexes.map { color(UInt32($0, radix: 16) ?? 0) },
                          atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -35)

// Text helper; y counts from the top, like the icon positions.
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        .paragraphStyle: paragraph,
    ]
    let string = text as NSString
    let h = string.boundingRect(with: NSSize(width: width - 60, height: 200), options: .usesLineFragmentOrigin,
                                attributes: attrs).height
    string.draw(in: NSRect(x: 30, y: height - y - h, width: width - 60, height: h), withAttributes: attrs)
}

draw("Drag \(appName) to Applications", size: 20, weight: .semibold, alpha: 0.95, y: 22)

// A light band behind the icons: Finder writes their names in black, unreadable on dark.
let band = NSRect(x: 40, y: height - 248, width: width - 80, height: 186)
color(0xFFF4E6, 0.92).setFill()
NSBezierPath(roundedRect: band, xRadius: 16, yRadius: 16).fill()

// The arrow between the app (x 165) and Applications (x 495), at icon height.
let arrowY = height - 150
let arrow = NSBezierPath()
arrow.lineWidth = 4
arrow.lineCapStyle = .round
arrow.move(to: NSPoint(x: 255, y: arrowY))
arrow.line(to: NSPoint(x: 400, y: arrowY))
arrow.move(to: NSPoint(x: 384, y: arrowY + 14))
arrow.line(to: NSPoint(x: 402, y: arrowY))
arrow.line(to: NSPoint(x: 384, y: arrowY - 14))
// In the darkest color of the gradient, so it matches the app.
color(UInt32(hexes[2], radix: 16) ?? 0x3A1E6B, 0.75).setStroke()
arrow.stroke()

// First launch, under the band.
draw("First time you open it", size: 13, weight: .semibold, alpha: 0.95, y: 268)
draw("macOS can't check apps from outside the App Store, so it asks first.\nOpen System Settings › Privacy & Security, scroll down, click Open Anyway.",
     size: 12, weight: .regular, alpha: 0.8, y: 290)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
