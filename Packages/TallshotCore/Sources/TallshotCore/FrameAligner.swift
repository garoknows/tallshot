/// How two frames in a row relate, as worked out by `FrameAligner`.
public enum Alignment: Equatable, Sendable {
    /// The content did not move (the frames are the same apart from small animated patches).
    case noMovement
    /// The content moved up by `layout.offset` pixels.
    case moved(PairLayout)
    /// No offset could be confirmed. The engine never guesses: the caller retries or stops.
    case uncertain(bestScore: Double)
}

/// The shape of one confirmed step.
public struct PairLayout: Equatable, Sendable {
    /// Rows at the top that stayed exactly the same in both frames (a sticky header, a toolbar).
    public var header: Int
    /// Rows at the bottom that stayed exactly the same (a chat input box, a sticky footer).
    public var footer: Int
    /// How many pixels the content moved up.
    public var offset: Int
    /// Fixed side panels at the left or right edge, and the flat color that fills them below
    /// their first appearance, so a fixed sidebar shows up once instead of on every strip.
    public var sidebars: [Sidebar]
    /// Share of the overlapping, informative rows that matched pixel for pixel (0...1).
    public var score: Double

    public init(header: Int, footer: Int, offset: Int, sidebars: [Sidebar] = [], score: Double = 1) {
        self.header = header; self.footer = footer; self.offset = offset; self.sidebars = sidebars; self.score = score
    }
}

public struct Sidebar: Equatable, Sendable {
    public var columns: Range<Int>
    public var fill: UInt32
}

/// Tuning for the line-up. The defaults are what the tests and the app use.
public struct AlignmentParameters: Sendable {
    /// Two frames count as "the same" when at least this share of rows is identical
    /// (leaves room for a blinking cursor or spinner).
    public var sameFraction = 0.97
    /// The moving area must keep at least this share of the frame height.
    public var minMiddleFraction = 0.2
    /// The two frames must overlap by at least this many rows of moving content.
    public var minOverlapRows = 12
    /// A step is confirmed only when this share of overlapping rows match exactly.
    public var confidence = 0.9
    /// At least this many overlapping rows must carry detail (not flat color) to confirm.
    public var minInformativeRows = 4
    /// How far from the requested scroll distance the first search looks (0.3 = ±30%).
    public var searchWindow = 0.3
    /// A fixed edge panel must be at least this share of the width to count as a sidebar.
    public var minSidebarFraction = 0.04

    public init() {}
}

/// Lines up two frames of the same scrolling area.
///
/// How it works, in order:
/// 1. Rows that are identical at the same height in both frames, starting from the top or the
///    bottom, are a fixed header or footer. They are left out of the matching.
/// 2. Columns that are identical everywhere in between are fixed too (a sidebar, a margin).
/// 3. Each remaining row gets a fingerprint (a hash of its moving pixels). Rows of the new frame
///    vote for the offsets at which an identical row exists in the old frame.
/// 4. The best-voted offsets are checked pixel for pixel. If none matches well enough, offsets
///    near the requested scroll distance are tried using coarse brightness profiles, and
///    again confirmed pixel for pixel. A weak match is reported as `.uncertain`, never used.
public struct FrameAligner: Sendable {
    public var parameters: AlignmentParameters

    public init(parameters: AlignmentParameters = AlignmentParameters()) {
        self.parameters = parameters
    }

    /// True when two frames are the same apart from small changing patches.
    public func isSame(_ a: PixelImage, _ b: PixelImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        var equal = 0
        for y in 0..<a.height where a.rowEquals(y, b, y) { equal += 1 }
        return Double(equal) >= parameters.sameFraction * Double(a.height)
    }

    /// Works out how `b` relates to `a`. `expected` is roughly how far the page was asked to
    /// scroll, in pixels; it narrows the fallback search and breaks ties.
    public func align(_ a: PixelImage, _ b: PixelImage, expected: Int? = nil) -> Alignment {
        precondition(a.width == b.width && a.height == b.height, "frames must be the same size")
        let H = a.height, W = a.width
        guard H > 0 else { return .noMovement }

        // 1. Rows identical at the same height.
        var equal = [Bool](repeating: false, count: H)
        var equalCount = 0
        for y in 0..<H where a.rowEquals(y, b, y) { equal[y] = true; equalCount += 1 }
        if Double(equalCount) >= parameters.sameFraction * Double(H) { return .noMovement }

        var header = 0
        while header < H && equal[header] { header += 1 }
        var footer = 0
        while footer < H - header && equal[H - 1 - footer] { footer += 1 }
        let minMiddle = max(parameters.minOverlapRows * 2, Int(Double(H) * parameters.minMiddleFraction))
        if H - header - footer < minMiddle { return .uncertain(bestScore: 0) }
        let M = H - header - footer

        // 2. Columns identical through the whole moving band.
        var fixed = [Bool](repeating: true, count: W)
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for y in header..<(H - footer) {
                    let base = y * W
                    for x in 0..<W where fixed[x] && pa[base + x] != pb[base + x] { fixed[x] = false }
                }
            }
        }
        let moving = ranges(of: fixed, value: false)
        if moving.isEmpty { return .noMovement }
        let sidebars = findSidebars(fixed: fixed, frame: a, rows: header..<(H - footer))

        // 3. Fingerprints of the moving band.
        let ha = (0..<M).map { rowHash(a, header + $0, moving) }
        let hb = (0..<M).map { rowHash(b, header + $0, moving) }
        let informative = (0..<M).map { !isFlat(b, header + $0, moving) }

        let maxOffset = M - max(parameters.minOverlapRows, 1)
        guard maxOffset >= 1 else { return .uncertain(bestScore: 0) }

        // Vote: a new-frame row y that equals old-frame row p suggests offset p - y.
        var positions: [UInt64: [Int]] = [:]
        for (p, h) in ha.enumerated() { positions[h, default: []].append(p) }
        var votes = [Int](repeating: 0, count: maxOffset + 1)
        for y in 0..<M where informative[y] {
            guard let ps = positions[hb[y]], ps.count <= 64 else { continue } // skip very repetitive rows
            for p in ps where p > y && p - y <= maxOffset { votes[p - y] += 1 }
        }
        var candidates = votes.indices.filter { votes[$0] > 0 }.sorted { votes[$0] > votes[$1] }
        candidates = Array(candidates.prefix(12))

        func score(_ d: Int) -> (Double, Int) {
            var matched = 0, counted = 0
            for y in 0..<(M - d) where informative[y] {
                counted += 1
                if hb[y] == ha[y + d] && b.rowEquals(header + y, a, header + y + d, columns: moving) { matched += 1 }
            }
            return (counted == 0 ? 0 : Double(matched) / Double(counted), counted)
        }

        var best: (d: Int, s: Double, n: Int)? = nil
        func consider(_ d: Int) {
            let (s, n) = score(d)
            guard n >= parameters.minInformativeRows else { return }
            if let cur = best {
                let better = s > cur.s + 0.0005
                let tie = abs(s - cur.s) <= 0.0005
                let closer = expected.map { abs(d - $0) < abs(cur.d - $0) } ?? (d < cur.d)
                if better || (tie && closer) { best = (d, s, n) }
            } else {
                best = (d, s, n)
            }
        }
        candidates.forEach(consider)

        // 4. Fallback: coarse profiles near the requested distance, still confirmed exactly.
        if (best?.s ?? 0) < parameters.confidence, let e = expected, e > 0 {
            let lo = max(1, Int(Double(e) * (1 - parameters.searchWindow)))
            let hi = min(maxOffset, Int((Double(e) * (1 + parameters.searchWindow)).rounded(.up)))
            if lo <= hi {
                let pa = (0..<M).map { profile(a, header + $0, moving) }
                let pb = (0..<M).map { profile(b, header + $0, moving) }
                var ranked: [(Int, Double)] = []
                for d in lo...hi {
                    var close = 0, n = 0
                    for y in stride(from: 0, to: M - d, by: 2) where informative[y] {
                        n += 1
                        if profilesClose(pb[y], pa[y + d]) { close += 1 }
                    }
                    if n > 0 { ranked.append((d, Double(close) / Double(n))) }
                }
                ranked.sort { $0.1 > $1.1 }
                for (d, _) in ranked.prefix(6) { consider(d) }
            }
        }

        guard let best, best.s >= parameters.confidence else { return .uncertain(bestScore: best?.s ?? 0) }
        return .moved(PairLayout(header: header, footer: footer, offset: best.d, sidebars: sidebars, score: best.s))
    }

    // MARK: Helpers

    /// Fixed blocks touching the left or right edge that carry detail are sidebars; they get
    /// filled with their most common color below their first appearance. Flat fixed blocks
    /// (plain margins) are not sidebars: copying them is already exact.
    func findSidebars(fixed: [Bool], frame: PixelImage, rows: Range<Int>) -> [Sidebar] {
        let W = fixed.count
        let minWidth = max(8, Int(Double(W) * parameters.minSidebarFraction))
        var result: [Sidebar] = []
        var left = 0
        while left < W && fixed[left] { left += 1 }
        var right = 0
        while right < W - left && fixed[W - 1 - right] { right += 1 }
        for block in [0..<left, (W - right)..<W] where block.count >= minWidth {
            // A column that is one color all the way down copies exactly as it is, so only
            // columns with detail (the sidebar's items) get painted over.
            var flat = [Bool](repeating: true, count: block.count)
            for (i, x) in block.enumerated() {
                let v = frame[x, rows.lowerBound]
                for y in rows where frame[x, y] != v { flat[i] = false; break }
            }
            let detailed = ranges(of: flat, value: false).map { ($0.lowerBound + block.lowerBound)..<($0.upperBound + block.lowerBound) }
            guard !detailed.isEmpty else { continue }
            var counts: [UInt32: Int] = [:]
            for cols in detailed {
                for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 2) {
                    for x in cols { counts[frame[x, y], default: 0] += 1 }
                }
            }
            guard let top = counts.max(by: { $0.value < $1.value }) else { continue }
            result.append(contentsOf: detailed.map { Sidebar(columns: $0, fill: top.key) })
        }
        return result
    }
}

/// Contiguous runs of `value` in a boolean array.
func ranges(of flags: [Bool], value: Bool) -> [Range<Int>] {
    var out: [Range<Int>] = []
    var start: Int? = nil
    for (i, f) in flags.enumerated() {
        if f == value { if start == nil { start = i } } else if let s = start { out.append(s..<i); start = nil }
    }
    if let s = start { out.append(s..<flags.count) }
    return out
}

/// A row fingerprint: FNV-1a hash of the row's pixels in the given columns.
@inline(__always)
func rowHash(_ img: PixelImage, _ y: Int, _ columns: [Range<Int>]) -> UInt64 {
    img.pixels.withUnsafeBufferPointer { p in
        var h: UInt64 = 0xcbf29ce484222325
        let base = y * img.width
        for c in columns {
            for x in c {
                h = (h ^ UInt64(p[base + x])) &* 0x100000001b3
            }
        }
        return h
    }
}

/// True when every pixel of the row (in the given columns) has the same value.
@inline(__always)
func isFlat(_ img: PixelImage, _ y: Int, _ columns: [Range<Int>]) -> Bool {
    img.pixels.withUnsafeBufferPointer { p in
        let base = y * img.width
        guard let first = columns.first?.first else { return true }
        let v = p[base + first]
        for c in columns { for x in c where p[base + x] != v { return false } }
        return true
    }
}

/// A coarse grayscale profile of a row: average brightness in 32 equal slices of its moving columns.
func profile(_ img: PixelImage, _ y: Int, _ columns: [Range<Int>]) -> [UInt16] {
    let xs = columns.flatMap { $0 }
    let bins = 32
    var sums = [Int](repeating: 0, count: bins), counts = [Int](repeating: 0, count: bins)
    img.pixels.withUnsafeBufferPointer { p in
        let base = y * img.width
        for (i, x) in xs.enumerated() {
            let b = i * bins / max(xs.count, 1)
            sums[b] += byteSum(p[base + x]); counts[b] += 1
        }
    }
    return (0..<bins).map { counts[$0] == 0 ? 0 : UInt16(sums[$0] / counts[$0]) }
}

@inline(__always)
func profilesClose(_ a: [UInt16], _ b: [UInt16]) -> Bool {
    for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 6 { return false }
    return true
}
