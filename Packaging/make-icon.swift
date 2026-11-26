// Builds MinePointer's app icons from the SVG sources in Packaging/Icon (NSImage reads SVG natively on macOS 14+).
// Usage: xcrun swift Packaging/make-icon.swift [Packaging/Icon] [Packaging]
// For every variant (<name>.svg master, <name>-16.svg and <name>-32.svg small drawings) it writes <out>/AppIcon-<name>.icns.
// The 16 and 32 px slots come from the small drawings, the rest from the master.
import AppKit

let args = CommandLine.arguments
let source = URL(fileURLWithPath: args.count > 1 ? args[1] : "Packaging/Icon")
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "Packaging")
let variants = ["green", "light", "graphite"]   // keep in step with AppIconChoice; build-minepointer.sh ships green as AppIcon.icns
let fm = FileManager.default

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

func svg(_ name: String) -> NSImage {
    let url = source.appendingPathComponent(name + ".svg")
    guard let image = NSImage(contentsOf: url) else { fail("cannot read \(url.path)") }
    return image
}

/// Draws the SVG at exactly `pixels` × `pixels` and encodes it as PNG.
func png(_ image: NSImage, pixels: Int) -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fail("cannot create bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { fail("cannot encode PNG") }
    return data
}

let tmp = fm.temporaryDirectory.appendingPathComponent("MinePointer-icon-\(UUID().uuidString)")
defer { try? fm.removeItem(at: tmp) }

for name in variants {
    let master = svg(name), small16 = svg(name + "-16"), small32 = svg(name + "-32")
    let iconset = tmp.appendingPathComponent("\(name).iconset")
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    let slots: [(String, NSImage, Int)] = [
        ("icon_16x16", small16, 16), ("icon_16x16@2x", small32, 32), ("icon_32x32", small32, 32), ("icon_32x32@2x", master, 64),
        ("icon_128x128", master, 128), ("icon_128x128@2x", master, 256), ("icon_256x256", master, 256),
        ("icon_256x256@2x", master, 512), ("icon_512x512", master, 512), ("icon_512x512@2x", master, 1024),
    ]
    for (slot, image, pixels) in slots {
        try png(image, pixels: pixels).write(to: iconset.appendingPathComponent(slot + ".png"))
    }
    let icns = outDir.appendingPathComponent("AppIcon-\(name).icns")
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { fail("iconutil failed for \(name)") }
    print("wrote \(icns.path)")
}
