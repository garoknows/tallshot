/// Generates test pages from code: numbered, barcoded rows with text-like blocks, so tests
/// never need a real screenshot. Pixels are RGBA bytes packed little-endian (R in the low byte).
public enum TestPage {
    public static let white: UInt32 = 0xFFFF_FFFF
    public static let black: UInt32 = 0xFF00_0000
    /// Where the barcode starts and how wide each cell is, in pixels at scale 1.
    public static let barcodeX = 4
    public static let cellWidth = 4
    public static var barcodeWidth: Int { Barcode.cellCount * cellWidth }

    public static func rgba(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) -> UInt32 {
        UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(a) << 24
    }

    /// A page `width` × `height` pixels. Row `y` carries barcode `firstIndex + y`.
    /// Every 22 rows starts a "line" of grey word blocks, laid out from `seed`.
    public static func make(width: Int, height: Int, seed: UInt64 = 1, firstIndex: Int = 0) -> PixelImage {
        var img = PixelImage(width: width, height: height, fill: white)
        paint(&img, rows: 0..<height, seed: seed, firstIndex: firstIndex)
        return img
    }

    /// Paints page rows into an existing image (used to grow a page while it is scrolled).
    public static func paint(_ img: inout PixelImage, rows: Range<Int>, seed: UInt64, firstIndex: Int) {
        let textX = barcodeX + barcodeWidth + 12
        for y in rows {
            let cells = Barcode.cells(for: firstIndex + y)
            for (c, dark) in cells.enumerated() where dark {
                for x in (barcodeX + c * cellWidth)..<(barcodeX + (c + 1) * cellWidth) where x < img.width { img[x, y] = black }
            }
            // Text-like blocks: lines 14 px tall with 8 px gaps.
            let line = (firstIndex + y) / 22, inLine = (firstIndex + y) % 22
            guard inLine >= 4 && inLine < 18 else { continue }
            var rng = SplitMix(seed: seed &+ UInt64(line) &* 0x9E37_79B9_7F4A_7C15)
            var x = textX
            let shade = UInt8(60 + rng.next() % 120)
            let color = rgba(shade, shade, UInt8(min(255, Int(shade) + 30)))
            while x < img.width - 8 {
                let w = 10 + Int(rng.next() % 60)
                for xx in x..<min(x + w, img.width - 8) { img[xx, y] = color }
                x += w + 6
                if rng.next() % 9 == 0 { break }
            }
        }
    }
}

/// A small, fast, seeded random number generator so generated pages are the same every run.
public struct SplitMix: Sendable {
    var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
