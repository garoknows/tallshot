import CoreGraphics
import Foundation
import ImageIO
import TallshotCore
import UniformTypeIdentifiers

/// Turns Tallshot's pixel grids into Core Graphics images and PNG data, all in memory.
public enum ImageBridge {
    /// A capture as a CGImage. Screen captures are BGRA (premultiplied, little-endian).
    public static func cgImage(_ img: PixelImage, colorSpace: CGColorSpace) -> CGImage? {
        let data = img.pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public static func png(_ cg: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
