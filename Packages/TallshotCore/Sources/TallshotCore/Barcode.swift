/// Row barcodes: every row of a test page carries its own row number as a strip of dark and
/// light cells. Reading the barcodes back out of a capture proves that every row came out
/// once, in order, with nothing repeated or missing. Used by the tests, the offscreen harness
/// and the in-app self-test.
public enum Barcode {
    /// Two guard cells (dark, light), 18 bits of row number, 6 check bits.
    public static let cellCount = 26
    static let indexBits = 18
    static let checkBits = 6
    public static let maxIndex = (1 << indexBits) - 1

    /// The cells for a row number, left to right. `true` means dark.
    public static func cells(for index: Int) -> [Bool] {
        precondition(index >= 0 && index <= maxIndex)
        var out = [true, false]
        for b in (0..<indexBits).reversed() { out.append((index >> b) & 1 == 1) }
        let check = checksum(index)
        for b in (0..<checkBits).reversed() { out.append((check >> b) & 1 == 1) }
        return out
    }

    static func checksum(_ index: Int) -> Int { (index &* 37 &+ 11 &+ (index >> 6) &* 5) & 63 }

    /// Reads the row number from one row of pixels. `originX` is where the first cell starts and
    /// `cellWidth` how wide each cell is, both in pixels. Returns nil if the row has no valid code.
    public static func decode(_ image: PixelImage, row y: Int, originX: Double, cellWidth: Double) -> Int? {
        var bits: [Bool] = []
        bits.reserveCapacity(cellCount)
        for c in 0..<cellCount {
            let x = Int(originX + (Double(c) + 0.5) * cellWidth)
            guard x >= 0 && x < image.width else { return nil }
            bits.append(byteSum(image[x, y]) < 640)
        }
        guard bits[0], !bits[1] else { return nil }
        var index = 0
        for b in bits[2..<(2 + indexBits)] { index = index << 1 | (b ? 1 : 0) }
        var check = 0
        for b in bits[(2 + indexBits)...] { check = check << 1 | (b ? 1 : 0) }
        return check == checksum(index) ? index : nil
    }
}

/// The result of reading every row's barcode in a capture.
public struct BarcodeReport: Sendable, Equatable {
    /// First and last row numbers found.
    public var first: Int?
    public var last: Int?
    /// Rows found, counted once each.
    public var distinctRows: Int
    /// Row numbers that should be there but aren't (gaps between first and last).
    public var missing: [Int]
    /// Row numbers that show up again after other rows (a repeat).
    public var repeated: [Int]
    /// Places where the numbers go backwards.
    public var outOfOrder: Int

    /// Every row from first to last is there once, in order.
    public var isClean: Bool { first != nil && missing.isEmpty && repeated.isEmpty && outOfOrder == 0 }

    /// Reads all rows. `pixelsPerRow` is the screen scale: on a Retina screen each page row
    /// spans two pixel rows. Rows without a valid code (headers, footers) are skipped.
    public static func read(_ image: PixelImage, originX: Double, cellWidth: Double, pixelsPerRow: Int = 1,
                            rows: Range<Int>? = nil) -> BarcodeReport {
        var runs: [(index: Int, length: Int)] = []
        for y in rows ?? 0..<image.height {
            guard let i = Barcode.decode(image, row: y, originX: originX, cellWidth: cellWidth) else { continue }
            if let lastRun = runs.last, lastRun.index == i { runs[runs.count - 1].length += 1 } else { runs.append((i, 1)) }
        }
        var seen = Set<Int>(), repeated: [Int] = [], missing: [Int] = [], backwards = 0
        for (k, run) in runs.enumerated() {
            if seen.contains(run.index) { repeated.append(run.index) }
            seen.insert(run.index)
            if k > 0 {
                let prev = runs[k - 1].index
                if run.index < prev { backwards += 1 } else if run.index > prev + 1 { missing.append(contentsOf: (prev + 1)..<run.index) }
            }
            // A run longer than one screen pixel row per page row means a row was stitched twice.
            let isEdge = k == 0 || k == runs.count - 1
            if !isEdge && run.length > pixelsPerRow { repeated.append(run.index) }
        }
        return BarcodeReport(first: runs.first?.index, last: runs.last?.index, distinctRows: seen.count,
                             missing: missing, repeated: repeated, outOfOrder: backwards)
    }
}
