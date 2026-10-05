// Generates Resources/AppIcon.icns: blue squircle, white shield, blue bolt.
//   swift Scripts/make_icon.swift
import AppKit

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.iconset")

func symbol(_ name: String, points: CGFloat, color: NSColor) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: points, weight: .semibold)
        .applying(.init(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / size
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)

    // Body: macOS icon grid (824pt squircle inside 1024) with a soft shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(red: 0.07, green: 0.20, blue: 0.55, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor(red: 0.20, green: 0.45, blue: 0.98, alpha: 1),
                        NSColor(red: 0.05, green: 0.17, blue: 0.52, alpha: 1)])!
        .draw(in: body, angle: -90)
    // Subtle top highlight.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 520, width: 824, height: 404), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Shield + bolt.
    let shield = symbol("shield.fill", points: 560, color: .white)
    let shieldRect = NSRect(x: (size - shield.size.width) / 2, y: (size - shield.size.height) / 2 - 8,
                            width: shield.size.width, height: shield.size.height)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    glow.shadowBlurRadius = 20
    glow.shadowOffset = NSSize(width: 0, height: -8)
    glow.set()
    shield.draw(in: shieldRect)
    NSGraphicsContext.restoreGraphicsState()

    let bolt = symbol("bolt.fill", points: 270, color: NSColor(red: 0.08, green: 0.25, blue: 0.70, alpha: 1))
    bolt.draw(in: NSRect(x: (size - bolt.size.width) / 2, y: (size - bolt.size.height) / 2 + 4,
                         width: bolt.size.width, height: bolt.size.height))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
