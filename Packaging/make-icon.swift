// Draws MinePointer's app icon: a macOS-style rounded square with a white SF Symbol on a green gradient.
// Usage: xcrun swift Packaging/make-icon.swift <out.icns>
// A full-size preview is written next to the output as <out>.png.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <out.icns>\n".utf8))
    exit(2)
}
let outPath = CommandLine.arguments[1]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

let symbolName = "airpods.chargingcase.fill"
guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
    fail("SF Symbol \(symbolName) is not available on this macOS")
}

/// Renders the icon on a 1024 pt canvas (Big Sur grid: 824 pt body, 100 pt margin) at 1 pixel per point.
func render1024() -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fail("cannot create bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    defer { NSGraphicsContext.restoreGraphicsState() }

    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Soft shadow under the body.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.30)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Vertical gradient: lighter grass green at the top, dark green at the bottom.
    let gradient = NSGradient(colors: [NSColor(srgbRed: 0.18, green: 0.58, blue: 0.27, alpha: 1),
                                       NSColor(srgbRed: 0.05, green: 0.25, blue: 0.13, alpha: 1)])!
    gradient.draw(in: path, angle: -90)

    // Thin inner highlight along the edge.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSColor(white: 1, alpha: 0.10).setStroke()
    let edge = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 183, yRadius: 183)
    edge.lineWidth = 3
    edge.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // White symbol in the middle, about half of the body.
    let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .regular)
        .applying(.init(paletteColors: [.white]))
    guard let glyph = symbol.withSymbolConfiguration(config) else { fail("cannot configure symbol") }
    let target = NSSize(width: 480, height: 480 * glyph.size.height / glyph.size.width)
    let glyphRect = NSRect(x: 512 - target.width / 2, y: 512 - target.height / 2, width: target.width, height: target.height)
    NSGraphicsContext.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor(white: 0, alpha: 0.25)
    glyphShadow.shadowOffset = NSSize(width: 0, height: -8)
    glyphShadow.shadowBlurRadius = 14
    glyphShadow.set()
    glyph.draw(in: glyphRect)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let master = render1024()
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("MinePointer-\(UUID().uuidString)")
let iconset = tmp.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

func writePNG(pixels: Int, name: String) throws {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let cg = master.cgImage else { fail("cannot scale icon") }
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let scaled = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else { fail("cannot encode PNG") }
    try png.write(to: iconset.appendingPathComponent(name))
}

for size in [16, 32, 128, 256, 512] {
    try writePNG(pixels: size, name: "icon_\(size)x\(size).png")
    try writePNG(pixels: size * 2, name: "icon_\(size)x\(size)@2x.png")
}
let preview = URL(fileURLWithPath: outPath).deletingPathExtension().appendingPathExtension("png")
try master.representation(using: .png, properties: [:])!.write(to: preview)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outPath]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }
