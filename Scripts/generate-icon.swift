import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-icon.swift <output.png>\n", stderr)
    exit(2)
}

let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Unable to allocate icon bitmap")
}

bitmap.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.setFill()
canvas.fill()

let tile = NSBezierPath(roundedRect: canvas.insetBy(dx: 52, dy: 52), xRadius: 205, yRadius: 205)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.17, green: 0.64, blue: 1.0, alpha: 1),
    NSColor(calibratedRed: 0.02, green: 0.44, blue: 0.91, alpha: 1),
])!
gradient.draw(in: tile, angle: -55)

let shield = NSBezierPath()
shield.move(to: NSPoint(x: 512, y: 820))
shield.curve(to: NSPoint(x: 760, y: 735), controlPoint1: NSPoint(x: 610, y: 798), controlPoint2: NSPoint(x: 688, y: 765))
shield.line(to: NSPoint(x: 733, y: 446))
shield.curve(to: NSPoint(x: 512, y: 218), controlPoint1: NSPoint(x: 718, y: 332), controlPoint2: NSPoint(x: 629, y: 254))
shield.curve(to: NSPoint(x: 291, y: 446), controlPoint1: NSPoint(x: 395, y: 254), controlPoint2: NSPoint(x: 306, y: 332))
shield.line(to: NSPoint(x: 264, y: 735))
shield.curve(to: NSPoint(x: 512, y: 820), controlPoint1: NSPoint(x: 336, y: 765), controlPoint2: NSPoint(x: 414, y: 798))
shield.close()
NSColor.white.setFill()
shield.fill()

let codeAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 170, weight: .bold),
    .foregroundColor: NSColor(calibratedRed: 0.02, green: 0.44, blue: 0.91, alpha: 1),
]
let code = NSAttributedString(string: "</>", attributes: codeAttributes)
let codeSize = code.size()
code.draw(at: NSPoint(x: (CGFloat(size) - codeSize.width) / 2, y: 430))

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode icon PNG")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
