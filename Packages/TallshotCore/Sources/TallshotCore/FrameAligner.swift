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
    /// How many of the `footer` rows are a floating overlay band (chips, a fade, a message box
    /// with see-through margins) rather than rows that stayed exactly the same. 0 when none.
    public var overlayBand: Int
    /// The columns whose pixels changed between the frames (left edge of the first moving
    /// column to the right edge of the last). A fallback capture is cropped to these.
    public var movingColumns: Range<Int>?

    public init(header: Int, footer: Int, offset: Int, sidebars: [Sidebar] = [], score: Double = 1,
                overlayBand: Int = 0, movingColumns: Range<Int>? = nil) {
        self.header = header; self.footer = footer; self.offset = offset; self.sidebars = sidebars; self.score = score
        self.overlayBand = overlayBand; self.movingColumns = movingColumns
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
    /// The rightmost sliver (this share of the width, 8 to 36 px) is left out of all matching,
    /// because overlay scroll bars show their knob there, at a different height in every frame.
    public var scrollerBandFraction = 0.025
    /// A floating overlay band at the bottom of the moving area (chips over the text, a fade,
    /// a message box with see-through margins) may be up to this share of the frame height.
    public var maxOverlayBandFraction = 0.4

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
/// 5. Floating overlays: chat apps float chips, a fade and a message box over the bottom of the
///    text, with see-through gaps. Those rows are neither fixed nor moving, so they never line
///    up. If the rows that fail sit together at the bottom of the overlap, they are treated as
///    an overlay band: left out of the match, and stitched once, from the last frame, like a footer.
public struct FrameAligner: Sendable {
    public var parameters: AlignmentParameters

    public init(parameters: AlignmentParameters = AlignmentParameters()) {
        self.parameters = parameters
    }

    /// True when two frames are the same apart from small changing patches.
    public func isSame(_ a: PixelImage, _ b: PixelImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        let cols = [0..<(a.width - scrollerBand(a.width))]
        var equal = 0
        for y in 0..<a.height where a.rowEquals(y, b, y, columns: cols) { equal += 1 }
        return Double(equal) >= parameters.sameFraction * Double(a.height)
    }

    /// Works out how `b` relates to `a`. `expected` is roughly how far the page was asked to
    /// scroll, in pixels; it narrows the fallback search and breaks ties.
    public func align(_ a: PixelImage, _ b: PixelImage, expected: Int? = nil) -> Alignment {
        precondition(a.width == b.width && a.height == b.height, "frames must be the same size")
        let H = a.height, W = a.width
        guard H > 0 else { return .noMovement }

        // 1. Rows identical at the same height.
        let band = scrollerBand(W)
        let rowCols = [0..<(W - band)]
        var equal = [Bool](repeating: false, count: H)
        var equalCount = 0
        for y in 0..<H where a.rowEquals(y, b, y, columns: rowCols) { equal[y] = true; equalCount += 1 }
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
        for x in (W - band)..<W { fixed[x] = true }   // never match on the scroll bar sliver
        let moving = ranges(of: fixed, value: false)
        if moving.isEmpty { return .noMovement }

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

        // 5. A floating overlay band at the bottom: trim the failing rows there and score the rest.
        func rowMatches(_ y: Int, _ d: Int) -> Bool {
            hb[y] == ha[y + d] && b.rowEquals(header + y, a, header + y + d, columns: moving)
        }
        let maxBand = Int(Double(H) * parameters.maxOverlayBandFraction)
        func bandScore(_ d: Int) -> (s: Double, n: Int, band: Int)? {
            let overlap = M - d
            guard overlap > parameters.minOverlapRows else { return nil }
            // Old-frame row y + d lies in the bottom `maxBand` rows of the moving area from here on.
            let zoneStart = max(0, M - maxBand - d)
            var cut = overlap
            for y in zoneStart..<overlap where !rowMatches(y, d) { cut = y; break }
            guard cut < overlap else { return nil }
            // Plain rows just above the first failure tell nothing (a fade over blank space looks
            // blank either way), so the band starts above them, at the last row with detail.
            while cut > 0 && !informative[cut - 1] { cut -= 1 }
            let band = M - (cut + d)
            guard cut >= parameters.minOverlapRows, M - band >= minMiddle else { return nil }
            var matched = 0, counted = 0
            for y in 0..<cut where informative[y] {
                counted += 1
                if rowMatches(y, d) { matched += 1 }
            }
            guard counted >= parameters.minInformativeRows else { return nil }
            return (Double(matched) / Double(counted), counted, band)
        }
        var banded: (d: Int, s: Double, n: Int, band: Int)? = nil
        var bandCandidates = candidates
        if let d = best?.d { bandCandidates.insert(d, at: 0) }
        if (best?.s ?? 0) < parameters.confidence, let e = expected, e > 0 {
            // Near the requested distance too, in case the votes were drowned out by the band.
            let lo = max(1, Int(Double(e) * (1 - parameters.searchWindow)))
            let hi = min(maxOffset, Int((Double(e) * (1 + parameters.searchWindow)).rounded(.up)))
            if lo <= hi { bandCandidates += Array(lo...hi).filter { votes[$0] > 0 && !bandCandidates.contains($0) } }
        }
        for d in bandCandidates {
            guard let r = bandScore(d), r.s >= parameters.confidence else { continue }
            if let cur = banded {
                let better = r.s > cur.s + 0.0005 || (abs(r.s - cur.s) <= 0.0005 && r.band < cur.band)
                if !better { continue }
            }
            banded = (d, r.s, r.n, r.band)
        }
        // What moved, widened over neighbouring columns that are one plain color all the way
        // down (a margin, the plain edge of the pane's own content), stopping at anything with
        // detail, at a thin divider line between panes, or after a twelfth of the width.
        var lo = moving.first!.lowerBound, hi = moving.last!.upperBound
        func plain(_ x: Int) -> UInt32? {
            let v = a[x, header]
            for y in header..<(H - footer) where a[x, y] != v || b[x, y] != v { return nil }
            return v
        }
        let thin = max(2, W / 500), cap = max(48, W / 12)
        func widen(from start: Int, step: Int) -> Int {
            var edge = start           // first column outside the span so far
            var inside: UInt32? = nil  // color of the run just inside (nil: moving content)
            while edge >= 0 && edge < W && abs(edge - start) < cap, let c = plain(edge) {
                var far = edge
                while far + step >= 0 && far + step < W && plain(far + step) == c { far += step }
                let width = abs(far - edge) + 1
                let outside = (far + step >= 0 && far + step < W) ? plain(far + step) : nil
                // A thin line with a different plain color on its far side divides two panes.
                if width <= thin, let o = outside, o != c, inside != c { break }
                inside = c
                edge = far + step
            }
            return edge
        }
        lo = widen(from: lo - 1, step: -1) + 1
        hi = widen(from: hi, step: 1)
        let span = lo..<hi
        // Prefer the band whenever it explains failing rows at the bottom: those rows hold a
        // floating overlay, and stitching them as content would repeat it on every strip.
        if let banded, banded.s > (best?.s ?? 0) || (best.map { $0.d == banded.d && $0.s < 1 } ?? true) {
            // Sidebars are judged only on rows above the band (a message box is not a sidebar).
            let sidebars = findSidebars(fixed: fixed, frame: a, rows: header..<(H - footer - banded.band))
            return .moved(PairLayout(header: header, footer: footer + banded.band, offset: banded.d, sidebars: sidebars,
                                     score: banded.s, overlayBand: banded.band, movingColumns: span))
        }
        guard let best, best.s >= parameters.confidence else { return .uncertain(bestScore: best?.s ?? 0) }
        let sidebars = findSidebars(fixed: fixed, frame: a, rows: header..<(H - footer))
        return .moved(PairLayout(header: header, footer: footer, offset: best.d, sidebars: sidebars, score: best.s,
                                 movingColumns: span))
    }

    // MARK: Helpers

    /// Width of the right-edge band where an overlay scroll bar may appear.
    public func scrollerBand(_ width: Int) -> Int {
        guard width >= 160 else { return 0 }
        return min(36, max(8, Int(Double(width) * parameters.scrollerBandFraction)))
    }

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
