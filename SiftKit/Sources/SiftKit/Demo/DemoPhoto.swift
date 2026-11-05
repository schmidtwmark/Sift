import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A picture for the demo's mail to carry, so there's a photo to open, share
/// and save without a real account.
enum DemoPhoto {
    /// A cliff against a sunset sky, as a JPEG.
    static func crag(width: Int = 1200, height: Int = 900) -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return Data() }
        let w = CGFloat(width), h = CGFloat(height)
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

        // Core Graphics counts up from the bottom.
        if let sky = CGGradient(colorsSpace: space,
                                colors: [color(0.98, 0.62, 0.36), color(0.85, 0.45, 0.55), color(0.22, 0.27, 0.52)] as CFArray,
                                locations: [0, 0.45, 1]) {
            context.drawLinearGradient(sky, start: CGPoint(x: 0, y: h * 0.25), end: CGPoint(x: 0, y: h),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.setFillColor(color(1, 0.86, 0.6))
        context.fillEllipse(in: CGRect(x: w * 0.6, y: h * 0.3, width: w * 0.11, height: w * 0.11))

        func fill(_ points: [(CGFloat, CGFloat)], _ shade: CGColor) {
            context.beginPath()
            context.addLines(between: points.map { CGPoint(x: $0.0 * w, y: $0.1 * h) })
            context.closePath()
            context.setFillColor(shade)
            context.fillPath()
        }
        // Far ridge, then the crag itself, then the ground.
        fill([(0, 0.25), (0.15, 0.38), (0.3, 0.32), (0.48, 0.45), (0.66, 0.34), (0.82, 0.42), (1, 0.3), (1, 0), (0, 0)],
             color(0.36, 0.3, 0.42))
        fill([(0.05, 0), (0.12, 0.5), (0.2, 0.72), (0.27, 0.86), (0.33, 0.83), (0.4, 0.6), (0.47, 0.42), (0.55, 0)],
             color(0.2, 0.16, 0.2))
        fill([(0, 0), (0, 0.12), (0.3, 0.16), (0.6, 0.1), (1, 0.14), (1, 0)], color(0.12, 0.12, 0.14))

        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
