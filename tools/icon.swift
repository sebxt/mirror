// Draws the 1024 px app icon: a white rounded square with a black camera.
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
NSGradient(starting: .white, ending: NSColor(white: 0.93, alpha: 1))!.draw(in: shape, angle: -90)
NSColor(white: 0, alpha: 0.08).setStroke()
shape.lineWidth = 2
shape.stroke()

let config = NSImage.SymbolConfiguration(pointSize: 380, weight: .medium)
    .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 0.11, alpha: 1)]))
let symbol = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let s = symbol.size
symbol.draw(in: NSRect(x: (CGFloat(size) - s.width) / 2, y: (CGFloat(size) - s.height) / 2, width: s.width, height: s.height))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
