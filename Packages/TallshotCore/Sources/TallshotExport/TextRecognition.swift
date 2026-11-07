import CoreGraphics
import Foundation
import TallshotCore
import Vision

/// On-device text recognition (Apple's Vision framework, accurate mode). Nothing leaves the Mac.
/// A tall capture is read in overlapping tiles, because Vision shrinks very tall images.
public enum TextRecognition {
    /// Whether Vision can run here (it can't inside some restricted sandboxes).
    public static var isAvailable: Bool {
        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let img = ctx?.makeImage() else { return false }
        let req = VNRecognizeTextRequest()
        return (try? VNImageRequestHandler(cgImage: img).perform([req])) != nil
    }

    /// Text lines in image pixels (top-left origin). `pixels` (the same image) lets each line be
    /// checked for a shaded box behind it (a code block).
    public static func lines(in image: CGImage, pixels: PixelImage? = nil) throws -> [TextLine] {
        let W = image.width, H = image.height
        let tileH = max(1200, Int(Double(W) * 1.4)), overlap = 160
        var out: [TextLine] = []
        var top = 0
        let page = pixels.map(background)   // once per image: never carried over from another capture
        while top < H {
            let bottom = min(H, top + tileH)
            guard let tile = image.cropping(to: CGRect(x: 0, y: top, width: W, height: bottom - top)) else { break }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: tile).perform([req])
            let th = Double(bottom - top)
            // Keep each line once: in the tile whose middle part holds its center.
            let keepFrom = Double(top == 0 ? 0 : top + overlap / 2), keepTo = Double(bottom == H ? H : bottom - overlap / 2)
            for o in req.results ?? [] {
                guard let text = o.topCandidates(1).first?.string else { continue }
                let b = o.boundingBox
                let x = Double(b.minX) * Double(W), w = Double(b.width) * Double(W)
                let y = Double(top) + (1 - Double(b.maxY)) * th, h = Double(b.height) * th
                let cy = y + h / 2
                guard cy >= keepFrom && cy < keepTo else { continue }
                out.append(TextLine(text: text, x: x, y: y, width: w, height: h, onShade: pixels.map { shaded($0, page: page ?? 0, x: x, y: y, w: w, h: h) } ?? false))
            }
            if bottom == H { break }
            top = bottom - overlap
        }
        return out.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
    }

    /// The most common color around a line differs from the page's: it sits on a shaded box.
    static func shaded(_ img: PixelImage, page: UInt32, x: Double, y: Double, w: Double, h: Double) -> Bool {
        let x0 = max(0, Int(x) - 4), x1 = min(img.width, Int(x + w) + 4)
        let y0 = max(0, Int(y) - 2), y1 = min(img.height, Int(y + h) + 2)
        guard x1 > x0, y1 > y0 else { return false }
        var counts: [UInt32: Int] = [:]
        for yy in stride(from: y0, to: y1, by: 2) { for xx in stride(from: x0, to: x1, by: 2) { counts[img[xx, yy], default: 0] += 1 } }
        guard let local = counts.max(by: { $0.value < $1.value })?.key else { return false }
        return abs(brightness(local) - brightness(page)) > 8
    }

    static func brightness(_ p: UInt32) -> Int { Int(p & 0xFF) + Int((p >> 8) & 0xFF) + Int((p >> 16) & 0xFF) }

    /// The page's most common color.
    static func background(_ img: PixelImage) -> UInt32 {
        var counts: [UInt32: Int] = [:]
        for y in stride(from: 0, to: img.height, by: max(1, img.height / 400)) {
            for x in stride(from: 0, to: img.width, by: max(1, img.width / 100)) { counts[img[x, y], default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value }?.key ?? 0
    }

    /// The document from recognized text: structure rebuilt from the layout.
    public static func document(from lines: [TextLine]) -> ExportDocument {
        ExportDocument(blocks: LayoutReader.blocks(from: lines), source: .recognized)
    }
}
