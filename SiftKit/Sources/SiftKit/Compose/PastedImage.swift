import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pictures pasted into a message arrive however the system held them: TIFF
/// on the Mac, and on iPhone a photo re-encoded as a PNG many times its
/// size. This makes them something any mail app shows, at a sensible size.
public enum PastedImage {
    /// An opaque PNG bigger than this goes as JPEG: it's a photo, not a screenshot.
    static let largePNG = 1_000_000

    /// JPEG and GIF stay as they are. Anything else becomes PNG, or JPEG when
    /// that PNG would be big and nothing in the picture is see-through.
    public static func mailable(_ data: Data, type: UTType) -> (data: Data, type: UTType) {
        if type.conforms(to: .jpeg) || type.conforms(to: .gif) { return (data, type) }
        if type.conforms(to: .png), data.count <= largePNG { return (data, type) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = type.conforms(to: .png) ? data : png(image)
        else { return (data, type) }
        if png.count > largePNG, isOpaque(image), let jpeg = encode(image, as: .jpeg, quality: 0.9) {
            return (jpeg, .jpeg)
        }
        return (png, .png)
    }

    public static func png(_ image: CGImage) -> Data? { encode(image, as: .png) }

    static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return nil }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: true
        default: false
        }
    }
}
