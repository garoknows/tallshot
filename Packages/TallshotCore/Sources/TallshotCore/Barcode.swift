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

/// Finds Tallshot barcodes anywhere in an image, at any size, and says whether the rows came
/// out right. Used after every capture: a normal capture has no barcodes and gets no verdict;
/// a capture of the self-test or the browser test page gets "Passed" or what went wrong.
public enum BarcodeCheck {
    public struct Placement: Equatable, Sendable {
        public var originX: Double
        public var cellWidth: Double
        /// Screen pixel rows per page row (2 on a Retina screen).
        public var pixelsPerRow: Int
    }

    public struct Verdict: Equatable, Sendable {
        public var passed: Bool
        public var report: BarcodeReport
        /// "Barcode check passed: rows 0 to 2,399 once each, in order."
        public var message: String
    }

    /// Where the barcode column is, or nil if the image has none. Samples rows down the image,
    /// tries every dark run as the start of a code at each cell width, and keeps the placement
    /// that decodes on the most rows, with row numbers that grow down the image.
    public static func locate(in image: PixelImage, rows: Range<Int>? = nil, samples: Int = 64) -> Placement? {
        let range = rows ?? 0..<image.height
        guard image.width >= Barcode.cellCount * 2, range.count >= 8 else { return nil }
        let widths = stride(from: 2.0, through: 20.0, by: 0.5).map { $0 }
        var hits: [Int: [(y: Int, index: Int)]] = [:]   // key: x * 64 + width step
        let n = min(samples, range.count)
        for k in 0..<n {
            let y = range.lowerBound + k * range.count / n
            var x = 1
            let limit = image.width - Barcode.cellCount * 2
            while x < limit {
                let dark = byteSum(image[x, y]) < 640, before = byteSum(image[x - 1, y]) < 640
                if dark && !before {
                    for (wi, cw) in widths.enumerated() where Double(x) + cw * Double(Barcode.cellCount) <= Double(image.width) {
                        if let i = Barcode.decode(image, row: y, originX: Double(x), cellWidth: cw) {
                            hits[x * 64 + wi, default: []].append((y, i))
                        }
                    }
                }
                x += 1
            }
        }
        // The best placement: most rows, and row numbers that never go backwards.
        // (A capture with a repeat goes backwards once; allow a few such places.)
        let ranked = hits.filter { _, v in zip(v, v.dropFirst()).filter { $0.index > $1.index }.count * 5 <= v.count }
            .max { $0.value.count < $1.value.count }
        guard let (key, found) = ranked, found.count >= max(6, n / 5) else { return nil }
        let cw = widths[key % 64]
        return Placement(originX: Double(key / 64), cellWidth: cw,
                         pixelsPerRow: max(1, Int((cw / Double(TestPage.cellWidth)).rounded(.up))))
    }

    /// The verdict for a finished capture, or nil when it has no Tallshot barcodes.
    /// `rows` limits the check to the content (leaving out a fixed header or overlay band).
    public static func verdict(for image: PixelImage, rows: Range<Int>? = nil) -> Verdict? {
        guard let p = locate(in: image, rows: rows) else { return nil }
        let report = BarcodeReport.read(image, originX: p.originX, cellWidth: p.cellWidth, pixelsPerRow: p.pixelsPerRow, rows: rows)
        guard let first = report.first, let last = report.last else { return nil }
        if report.isClean {
            return Verdict(passed: true, report: report,
                           message: "Barcode check passed: rows \(grouped(first)) to \(grouped(last)) once each, in order.")
        }
        var why: [String] = []
        if !report.missing.isEmpty { why.append("\(grouped(report.missing.count)) rows missing (first at \(grouped(report.missing[0])))") }
        if !report.repeated.isEmpty { why.append("\(grouped(report.repeated.count)) repeated (first at \(grouped(report.repeated[0])))") }
        if report.outOfOrder > 0 { why.append("\(report.outOfOrder) out of order") }
        return Verdict(passed: false, report: report, message: "Barcode check failed: \(why.joined(separator: ", ")).")
    }

    static func grouped(_ n: Int) -> String {
        var s = String(n), out = ""
        while s.count > 3 { out = "," + s.suffix(3) + out; s = String(s.dropLast(3)) }
        return s + out
    }
}
