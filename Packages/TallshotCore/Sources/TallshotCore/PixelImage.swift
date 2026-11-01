/// A picture as a plain grid of 32-bit pixels, row by row from the top.
///
/// The engine never looks inside a pixel except to sum its four bytes for brightness, so the
/// channel order (BGRA from the screen, RGBA from a test) doesn't matter as long as one capture
/// uses one order throughout.
public struct PixelImage: Equatable, Sendable {
    public let width: Int
    public private(set) var height: Int
    public private(set) var pixels: [UInt32]

    public init(width: Int, height: Int, pixels: [UInt32]) {
        precondition(width > 0 && height >= 0 && pixels.count == width * height, "pixel count must be width × height")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt32) {
        self.init(width: width, height: height, pixels: [UInt32](repeating: fill, count: width * height))
    }

    @inline(__always) public subscript(x: Int, y: Int) -> UInt32 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// One row of pixels.
    public func row(_ y: Int) -> ArraySlice<UInt32> {
        pixels[(y * width)..<((y + 1) * width)]
    }

    /// A copy of a band of rows.
    public func rows(_ range: Range<Int>) -> PixelImage {
        precondition(range.lowerBound >= 0 && range.upperBound <= height)
        return PixelImage(width: width, height: range.count,
                          pixels: Array(pixels[(range.lowerBound * width)..<(range.upperBound * width)]))
    }

    /// True when row `y` of this image equals row `otherY` of `other` in the given columns.
    @inline(__always)
    public func rowEquals(_ y: Int, _ other: PixelImage, _ otherY: Int, columns: [Range<Int>]? = nil) -> Bool {
        pixels.withUnsafeBufferPointer { a in
            other.pixels.withUnsafeBufferPointer { b in
                let ab = a.baseAddress! + y * width, bb = b.baseAddress! + otherY * other.width
                guard let columns else {
                    return memcmpEqual(ab, bb, count: width)
                }
                for c in columns where !memcmpEqual(ab + c.lowerBound, bb + c.lowerBound, count: c.count) {
                    return false
                }
                return true
            }
        }
    }

    // MARK: Building a tall image

    mutating func reserveRows(_ n: Int) { pixels.reserveCapacity((height + n) * width) }

    /// Appends rows `range` of `source`, optionally painting some columns a flat color.
    mutating func appendRows(of source: PixelImage, _ range: Range<Int>, paint: [(Range<Int>, UInt32)] = []) {
        precondition(source.width == width)
        guard !range.isEmpty else { return }
        let start = pixels.count
        pixels.append(contentsOf: source.pixels[(range.lowerBound * width)..<(range.upperBound * width)])
        if !paint.isEmpty {
            pixels.withUnsafeMutableBufferPointer { p in
                for r in 0..<range.count {
                    let base = start + r * width
                    for (cols, color) in paint {
                        for x in cols { p[base + x] = color }
                    }
                }
            }
        }
        height += range.count
    }

    /// Removes the last `n` rows.
    mutating func dropLastRows(_ n: Int) {
        let n = min(n, height)
        pixels.removeLast(n * width)
        height -= n
    }

    /// Keeps only the first `n` rows.
    mutating func truncate(toHeight n: Int) {
        guard n < height else { return }
        dropLastRows(height - n)
    }
}

@inline(__always)
func memcmpEqual(_ a: UnsafePointer<UInt32>, _ b: UnsafePointer<UInt32>, count: Int) -> Bool {
    var i = 0
    while i < count {
        if a[i] != b[i] { return false }
        i += 1
    }
    return true
}

/// Brightness of one pixel on a 0...1020 scale: the sum of its four bytes. Order-agnostic.
@inline(__always)
func byteSum(_ p: UInt32) -> Int {
    Int(p & 0xFF) + Int((p >> 8) & 0xFF) + Int((p >> 16) & 0xFF) + Int(p >> 24)
}

public extension PixelImage {
    /// A copy of a band of columns (used to crop a fallback capture to what moved).
    func columns(_ range: Range<Int>) -> PixelImage {
        precondition(range.lowerBound >= 0 && range.upperBound <= width && !range.isEmpty)
        var out: [UInt32] = []
        out.reserveCapacity(range.count * height)
        for y in 0..<height { out.append(contentsOf: pixels[(y * width + range.lowerBound)..<(y * width + range.upperBound)]) }
        return PixelImage(width: range.count, height: height, pixels: out)
    }
}
