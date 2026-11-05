import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SiftKit

@Suite struct PastedImageTests {
    /// Random pixels, which no format can squeeze, so the files come out big.
    func noise(width: Int = 1200, height: Int = 900, alpha: Bool) -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue)!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var generator = SystemRandomNumberGenerator()
        for index in 0..<(context.bytesPerRow * height) { pixels[index] = .random(in: 0...255, using: &generator) }
        return context.makeImage()!
    }

    @Test func jpegAndSmallPNGStayAsTheyAre() {
        let jpeg = DemoPhoto.crag()
        #expect(PastedImage.mailable(jpeg, type: .jpeg).data == jpeg)

        let small = PastedImage.png(noise(width: 100, height: 100, alpha: false))!
        let result = PastedImage.mailable(small, type: .png)
        #expect(result.type == .png)
        #expect(result.data == small)
    }

    @Test func aBigOpaquePNGGoesAsJPEG() throws {
        let png = try #require(PastedImage.png(noise(alpha: false)))
        #expect(png.count > PastedImage.largePNG)
        let result = PastedImage.mailable(png, type: .png)
        #expect(result.type == .jpeg)
        #expect(result.data.count < png.count)
    }

    @Test func aBigSeeThroughPNGStaysPNG() throws {
        let png = try #require(PastedImage.png(noise(alpha: true)))
        #expect(PastedImage.mailable(png, type: .png).type == .png)
    }

    @Test func tiffBecomesPNG() throws {
        let tiff = try #require(PastedImage.encode(noise(width: 64, height: 64, alpha: true), as: .tiff))
        let result = PastedImage.mailable(tiff, type: .tiff)
        #expect(result.type == .png)
        let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
    }
}
