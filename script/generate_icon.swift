import AppKit
import Foundation
let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
let variants = [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")]
for (pixels, label) in variants {
    let size = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let base = NSBezierPath(roundedRect: NSRect(x: size * 0.06, y: size * 0.06, width: size * 0.88, height: size * 0.88), xRadius: size * 0.21, yRadius: size * 0.21)
    NSColor(calibratedRed: 0.055, green: 0.15, blue: 0.16, alpha: 1).setFill(); base.fill()
    let heights: [CGFloat] = [0.14,0.27,0.42,0.53,0.36,0.23,0.12]
    for index in 0..<7 {
        let height = size * heights[index]
        NSColor(calibratedRed: 0.62, green: 0.94, blue: 0.83, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: size * (0.25 + CGFloat(index) * 0.073), y: (size - height) / 2, width: size * 0.037, height: height), xRadius: size * 0.0185, yRadius: size * 0.0185).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory + "/icon_" + label + ".png"))
}
