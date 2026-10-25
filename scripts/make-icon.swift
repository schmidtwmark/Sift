// Draws Sift's app icon and writes every size the asset catalog uses.
//
//   swift scripts/make-icon.swift
import AppKit
import CoreGraphics

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Full-bleed background (the OS applies the mask).
let colors = [CGColor(srgbRed: 0.10, green: 0.23, blue: 0.29, alpha: 1), CGColor(srgbRed: 0.16, green: 0.36, blue: 0.40, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size, y: size), options: [])
// Three bars narrowing downward: mail being sifted. Centred vertically.
let bars: [(width: CGFloat, y: CGFloat, alpha: CGFloat)] = [(620, 604, 1.0), (470, 474, 0.85), (300, 344, 0.7)]
for bar in bars {
    let rect = CGRect(x: (CGFloat(size) - bar.width) / 2, y: bar.y, width: bar.width, height: 76)
    ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.95, blue: 0.86, alpha: bar.alpha))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 38, cornerHeight: 38, transform: nil))
    ctx.fillPath()
}

let folder = URL(fileURLWithPath: CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? ".")
    .appending(path: "../Sift/Assets.xcassets/AppIcon.appiconset")
let master = NSBitmapImageRep(cgImage: ctx.makeImage()!)

func write(_ pixels: Int, to name: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy,
                fraction: 1, respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: folder.appending(path: name))
}

try master.representation(using: .png, properties: [:])!.write(to: folder.appending(path: "icon-1024.png"))
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    try write(pixels, to: "mac-\(pixels).png")
}
print("Wrote icons to \(folder.standardized.path)")
