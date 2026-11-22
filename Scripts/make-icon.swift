import AppKit
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let canvas = NSSize(width: 1024, height: 1024)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func tintedImage(_ image: NSImage, color: NSColor) -> NSImage {
    let result = NSImage(size: image.size)
    result.lockFocus()
    color.setFill()
    NSRect(origin: .zero, size: image.size).fill()
    image.draw(
        in: NSRect(origin: .zero, size: image.size),
        from: .zero,
        operation: .destinationIn,
        fraction: 1
    )
    result.unlockFocus()
    return result
}

let image = NSImage(size: canvas)
image.lockFocus()
guard let context = NSGraphicsContext.current else { fatalError("No graphics context") }
context.imageInterpolation = .high
context.shouldAntialias = true

NSColor.clear.setFill()
NSRect(origin: .zero, size: canvas).fill()

// The icon plate follows the spacious modern macOS app-icon grid.
let plateRect = NSRect(x: 74, y: 74, width: 876, height: 876)
let plate = NSBezierPath(roundedRect: plateRect, xRadius: 202, yRadius: 202)

let backgroundShadow = NSShadow()
backgroundShadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
backgroundShadow.shadowBlurRadius = 34
backgroundShadow.shadowOffset = NSSize(width: 0, height: -12)
NSGraphicsContext.saveGraphicsState()
backgroundShadow.set()
color(0x0B1631).setFill()
plate.fill()
NSGraphicsContext.restoreGraphicsState()

let gradient = NSGradient(colors: [color(0x111B3C), color(0x1D4ED8), color(0x2E86FF)])!
gradient.draw(in: plate, angle: -58)

// Hairline rim.
NSGraphicsContext.saveGraphicsState()
let rim = NSBezierPath(roundedRect: plateRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 200, yRadius: 200)
rim.lineWidth = 3
NSColor.white.withAlphaComponent(0.17).setStroke()
rim.stroke()
NSGraphicsContext.restoreGraphicsState()

// Earcon/speaker glyph.
let symbolConfig = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
if let symbol = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(symbolConfig) {
    let tinted = tintedImage(symbol, color: NSColor.white)
    let symbolSize = tinted.size
    let targetHeight: CGFloat = 432
    let targetWidth = targetHeight * (symbolSize.width / symbolSize.height)
    let targetRect = NSRect(
        x: (canvas.width - targetWidth) / 2 + 18,
        y: (canvas.height - targetHeight) / 2 + 24,
        width: targetWidth,
        height: targetHeight
    )

    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    glyphShadow.shadowBlurRadius = 28
    glyphShadow.shadowOffset = NSSize(width: 0, height: -10)
    NSGraphicsContext.saveGraphicsState()
    glyphShadow.set()
    tinted.draw(in: targetRect, from: .zero, operation: .sourceOver, fraction: 0.98)
    NSGraphicsContext.restoreGraphicsState()
}

// A tiny level indicator gives the icon its audio-control personality.
let pill = NSBezierPath(roundedRect: NSRect(x: 312, y: 214, width: 400, height: 20), xRadius: 10, yRadius: 10)
NSColor.white.withAlphaComponent(0.19).setFill()
pill.fill()

let fill = NSBezierPath(roundedRect: NSRect(x: 312, y: 214, width: 262, height: 20), xRadius: 10, yRadius: 10)
NSColor.white.withAlphaComponent(0.93).setFill()
fill.fill()

let knob = NSBezierPath(ovalIn: NSRect(x: 550, y: 198, width: 52, height: 52))
NSColor.white.setFill()
knob.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon")
}

try png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
