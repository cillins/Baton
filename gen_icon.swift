import AppKit
import Foundation

private let frames: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

private let masterURL = URL(fileURLWithPath: "Resources/BatonIconMaster.png")
private let outputURL = URL(fileURLWithPath: "Baton.iconset")

guard let masterImage = NSImage(contentsOf: masterURL) else {
    fatalError("Unable to load \(masterURL.path)")
}

try FileManager.default.createDirectory(
    at: outputURL,
    withIntermediateDirectories: true
)

for frame in frames {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: frame.pixels,
        pixelsHigh: frame.pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Unable to allocate \(frame.name)")
    }

    bitmap.size = NSSize(width: frame.pixels, height: frame.pixels)
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Unable to create graphics context for \(frame.name)")
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.clear(
        CGRect(x: 0, y: 0, width: frame.pixels, height: frame.pixels)
    )
    masterImage.draw(
        in: NSRect(x: 0, y: 0, width: frame.pixels, height: frame.pixels),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode \(frame.name)")
    }
    try png.write(to: outputURL.appendingPathComponent(frame.name))
}

print("Wrote \(frames.count) frames from \(masterURL.path)")
