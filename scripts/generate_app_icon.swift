import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("usage: swift generate_app_icon.swift OUTPUT_DIR\n", stderr)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

let variants: [(String, Int)] = [
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

guard let symbol = NSImage(
    systemSymbolName: "visionpro",
    accessibilityDescription: "EVA-VR"
) else {
    fputs("visionpro system symbol is unavailable\n", stderr)
    exit(1)
}

for (filename, pixels) in variants {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "EVA-VR.Icon", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "EVA-VR.Icon", code: 2)
    }
    NSGraphicsContext.current = context

    let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    let radius = CGFloat(pixels) * 0.22
    let background = NSBezierPath(roundedRect: canvas.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
    NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1).setFill()
    background.fill()

    let sizeConfiguration = NSImage.SymbolConfiguration(
        pointSize: CGFloat(pixels) * 0.52,
        weight: .medium
    )
    let colorConfiguration = NSImage.SymbolConfiguration(paletteColors: [.white])
    let configuration = sizeConfiguration.applying(colorConfiguration)
    let configured = symbol.withSymbolConfiguration(configuration) ?? symbol
    let symbolSize = configured.size
    let targetWidth = CGFloat(pixels) * 0.68
    let scale = targetWidth / max(symbolSize.width, 1)
    let targetSize = NSSize(
        width: symbolSize.width * scale,
        height: symbolSize.height * scale
    )
    let targetRect = NSRect(
        x: (CGFloat(pixels) - targetSize.width) / 2,
        y: (CGFloat(pixels) - targetSize.height) / 2,
        width: targetSize.width,
        height: targetSize.height
    )
    NSColor.white.set()
    configured.draw(in: targetRect)

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "EVA-VR.Icon", code: 3)
    }
    try data.write(to: outputDirectory.appendingPathComponent(filename))
}
