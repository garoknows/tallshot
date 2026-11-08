import CoreGraphics
import Foundation
import ImageIO
import TallshotCore
import UniformTypeIdentifiers

/// Turns Tallshot's pixel grids into Core Graphics images and PNG data, all in memory.
public enum ImageBridge {
    /// Holds the pixels for as long as Core Graphics needs them. The array is shared, not copied.
    private final class PixelSource {
        let pixels: [UInt32]
        init(_ pixels: [UInt32]) { self.pixels = pixels }
    }

    /// A capture as a CGImage. Screen captures are BGRA (premultiplied, little-endian).
    ///
    /// The image reads the capture's own pixels: Core Graphics asks for them a piece at a time
    /// while it encodes or draws, so a very tall capture isn't held twice in memory.
    public static func cgImage(_ img: PixelImage, colorSpace: CGColorSpace) -> CGImage? {
        let source = Unmanaged.passRetained(PixelSource(img.pixels))
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                guard let info else { return 0 }
                let pixels = Unmanaged<PixelSource>.fromOpaque(info).takeUnretainedValue().pixels
                return pixels.withUnsafeBytes { raw in
                    let start = Int(position)
                    guard start >= 0, start < raw.count, let base = raw.baseAddress else { return 0 }
                    let n = min(count, raw.count - start)
                    buffer.copyMemory(from: base + start, byteCount: n)
                    return n
                }
            },
            releaseInfo: { info in
                if let info { Unmanaged<PixelSource>.fromOpaque(info).release() }
            })
        // If this fails, Core Graphics never took the source, so it is simply kept (a few bytes).
        guard let provider = CGDataProvider(directInfo: source.toOpaque(), size: off_t(img.pixels.count * 4), callbacks: &callbacks) else { return nil }
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
