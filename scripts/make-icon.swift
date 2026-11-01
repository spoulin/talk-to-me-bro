// Draws the app icon (a page that speaks) into Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// The design is drawn on a 120-point square, placed on the macOS icon grid
/// (an 824/1024 rounded square with room for its shadow).
func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let canvas = CGFloat(pixels)
    let unit = canvas * 824 / 1024 / 120
    let origin = canvas * 100 / 1024
    // Top-left origin, in design points.
    let transform = NSAffineTransform()
    transform.translateX(by: origin, yBy: canvas - origin)
    transform.scaleX(by: unit, yBy: -unit)
    transform.concat()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = canvas * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.008)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    color(0xF2994A).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 120, height: 120), xRadius: 27, yRadius: 27).fill()
    NSGraphicsContext.restoreGraphicsState()

    color(0xFFF8EE).setFill()
    NSBezierPath(roundedRect: NSRect(x: 22, y: 24, width: 50, height: 70), xRadius: 6, yRadius: 6).fill()
    color(0xE07B2A).setFill()
    NSBezierPath(roundedRect: NSRect(x: 30, y: 36, width: 34, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
    color(0xC9B8A3).setFill()
    for (y, width) in [(48.0, 28.0), (57, 32), (66, 24), (75, 30)] {
        NSBezierPath(roundedRect: NSRect(x: 30, y: y, width: width, height: 4), xRadius: 2, yRadius: 2).fill()
    }

    // Sound waves: arcs through (80, 48)–(80, 72) and (88, 38)–(88, 82).
    NSColor.white.setStroke()
    for (x, halfChord, radius) in [(80.0, 12.0, 16.0), (88, 22, 30)] {
        let centerX = x - (radius * radius - halfChord * halfChord).squareRoot()
        let angle = atan2(halfChord, x - centerX) * 180 / .pi
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: centerX, y: 60), radius: radius, startAngle: -angle, endAngle: angle)
        arc.lineWidth = 6
        arc.lineCapStyle = .round
        arc.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(pixels: 1024).write(to: root.appendingPathComponent("Resources/AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "✓ Resources/AppIcon.icns" : "iconutil failed")
