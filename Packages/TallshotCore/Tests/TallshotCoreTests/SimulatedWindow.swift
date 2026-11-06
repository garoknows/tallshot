import TallshotCore

/// A pretend scrolling window, drawn from code. It shows part of a tall generated page,
/// optionally with a fixed header, footer and sidebar, and reacts to scroll requests the way a
/// real app might: with jitter, smooth scrolling, animated patches, transient overlays,
/// pages that grow when you reach the bottom, and a user who interrupts.
@MainActor
final class SimulatedWindow: CaptureDriver {
    let width: Int
    let height: Int
    var page: PixelImage
    var pageSeed: UInt64
    var pageFirstIndex = 0
    var header: PixelImage?
    var footer: PixelImage?
    var sidebar: PixelImage?
    var pos: Int

    // Behaviours
    var jitter = false
    var invertScroll = false
    var overlayScroller = false
    var smoothFrames = 0
    var fixedPatch = false
    var contentPatch = false
    var growStep = 0
    var growLimit = 0
    var cancelAfterCaptures: Int?
    var overlayCaptures: Set<Int> = []
    var replaceContentAfterScrolls: Int?
    /// Ways of scrolling this window ignores (ScrollMethod raw values), like Chromium ignoring a
    /// vertical gesture that carries Shift.
    var ignoredMethods: Set<ScrollMethod> = []
    /// Ways of scrolling this window can't do at all (most have no settable scroll bar).
    var unsupportedMethods: Set<ScrollMethod> = [.scrollBar]
    private(set) var method = ScrollMethod.gesture
    private(set) var methodsTried: [ScrollMethod] = []
    /// Momentum: every request with these methods moves a random 2 to 4 times further,
    /// usually with an animated glide (`smoothFrames`).
    var overshoot: ClosedRange<Double>?
    var overshootMethods: Set<ScrollMethod> = [.gesture, .wheelPixels]
    /// A chat that loads older messages when you reach the top: `hiddenTop` rows are not loaded
    /// yet; each load reveals `loadRows` more, `loadDelay` seconds after reaching the top.
    var hiddenTop = 0
    var loadRows = 400
    var loadDelay = 0.8
    private var loadRequestedAt: Double?
    /// Floating overlays above the footer: chips with see-through gaps, a fade over the text,
    /// and a message box with see-through margins (content scrolls under all of them).
    var chipsBand = 0
    var fadeBand = 0
    var composerMargin = 0

    /// Cards on the page, one every this many rows (64 rows tall). The card under the middle of
    /// the view lights up, the way an element under the scroll point does when hovered.
    var hoverCardEvery = 0
    /// A patch blinking in the sidebar, as a chat that's running shows in a chat list. Tall enough
    /// that frames with no scrolling don't count as the same.
    var sidebarSpinner = false

    private(set) var captures = 0
    private(set) var scrolls = 0
    private(set) var clock = 0.0
    private var rng = SplitMix(seed: 42)
    private var anim: (from: Int, to: Int, left: Int)?

    var h: Int { header?.height ?? 0 }
    var f: Int { footer?.height ?? 0 }
    var s: Int { sidebar?.width ?? 0 }
    var middle: Int { height - h - f }
    var maxPos: Int { max(0, page.height - middle) }

    init(width: Int = 360, height: Int = 400, pageHeight: Int = 3000, seed: UInt64 = 1, start: Int = 0,
         header: Int = 0, footer: Int = 0, sidebar: Int = 0) {
        self.width = width
        self.height = height
        self.pageSeed = seed
        self.page = TestPage.make(width: width - sidebar, height: pageHeight, seed: seed)
        self.pos = start
        if header > 0 { self.header = Self.band(width: width, height: header, color: TestPage.rgba(40, 60, 120), seed: seed &+ 7) }
        if footer > 0 { self.footer = Self.band(width: width, height: footer, color: TestPage.rgba(230, 230, 236), seed: seed &+ 9) }
        if sidebar > 0 { self.sidebar = Self.sidebarImage(width: sidebar, height: height - header - footer) }
    }

    /// A fixed bar with a few blocks on it (a toolbar or a chat input box).
    static func band(width: Int, height: Int, color: UInt32, seed: UInt64) -> PixelImage {
        var img = PixelImage(width: width, height: height, fill: color)
        var r = SplitMix(seed: seed)
        for _ in 0..<5 {
            let x0 = Int(r.next() % UInt64(max(1, width - 40))), y0 = Int(r.next() % UInt64(max(1, height - 8)))
            for y in y0..<min(height, y0 + 8) { for x in x0..<min(width, x0 + 30) { img[x, y] = TestPage.rgba(250, 200, 60) } }
        }
        return img
    }

    static let sidebarBackground = TestPage.rgba(238, 236, 230)

    /// A fixed side panel: a light background with menu items near the top.
    static func sidebarImage(width: Int, height: Int) -> PixelImage {
        var img = PixelImage(width: width, height: height, fill: sidebarBackground)
        for item in 0..<8 {
            let y0 = 10 + item * 24
            guard y0 + 12 < height else { break }
            for y in y0..<(y0 + 12) { for x in 8..<(width - 8 - (item * 5) % 20) { img[x, y] = TestPage.rgba(120, 120, 130) } }
        }
        return img
    }

    // MARK: CaptureDriver

    func captureFrame() async throws -> PixelImage {
        captures += 1
        clock += 0.03
        checkLoad()
        if let c = cancelAfterCaptures, captures >= c { cancelled = true }
        if overlayCaptures.contains(captures) {
            // A transient popup covering everything, the same on every capture while it shows.
            return Self.band(width: width, height: height, color: TestPage.rgba(90, 20, 20), seed: 99)
        }
        var shown = pos
        if let a = anim {
            let step = smoothFrames - a.left + 1
            shown = a.from + (a.to - a.from) * step / (smoothFrames + 1)
            anim = a.left > 1 ? (a.from, a.to, a.left - 1) : nil
        }
        return render(at: shown)
    }

    func render(at p: Int) -> PixelImage {
        var img = PixelImage(width: width, height: height, fill: TestPage.white)
        if let header { for y in 0..<h { for x in 0..<width { img[x, y] = header[x, y] } } }
        if let footer, composerMargin == 0 { for y in 0..<f { for x in 0..<width { img[x, height - f + y] = footer[x, y] } } }
        for r in 0..<(composerMargin > 0 ? height - h : middle) {
            let py = p + r
            if py < page.height { for x in 0..<page.width { img[s + x, h + r] = page[x, py] } }
            if let sidebar, r < middle { for x in 0..<s { img[x, h + r] = sidebar[x, r] } }
        }
        if let footer, composerMargin > 0 {
            // A message box floating over the text, with see-through margins around it.
            for y in 0..<(f - composerMargin) { for x in composerMargin..<(width - composerMargin) { img[x, height - f + y] = footer[x, y] } }
        }
        if fadeBand > 0 {
            // A fade from clear to white over the bottom of the text.
            let top = height - f - chipsBand - fadeBand
            for r in 0..<(fadeBand + chipsBand) {
                let alpha = min(1.0, Double(r + 1) / Double(fadeBand + 1)) * 0.85
                for x in 0..<width { img[x, top + r] = Self.blend(img[x, top + r], TestPage.white, alpha) }
            }
        }
        if chipsBand > 0 {
            // Action chips floating over the text, with gaps between them.
            let top = height - f - chipsBand
            for y in (top + 6)..<(top + chipsBand - 6) {
                for x0 in stride(from: s + 150, to: width - 70, by: 90) { for x in x0..<(x0 + 60) { img[x, y] = TestPage.rgba(225, 232, 250) } }
            }
        }
        if loadRequestedAt != nil {
            // A loading spinner at the top while older messages load.
            let c = TestPage.rgba(UInt8(captures * 53 % 256), 120, 220)
            for y in (h + 4)..<(h + 10) { for x in (width / 2)..<(width / 2 + 6) { img[x, y] = c } }
        }
        if fixedPatch {
            // A spinner fixed on screen, a different color on every capture.
            let c = TestPage.rgba(UInt8(captures * 37 % 256), UInt8(captures * 91 % 256), 200)
            for y in (height / 2)..<(height / 2 + 10) { for x in (width - 60)..<(width - 50) { img[x, y] = c } }
        }
        if overlayScroller {
            // A macOS overlay scroll bar: a grey knob at the right edge, placed by scroll position.
            let knobH = max(20, middle * middle / max(page.height, 1))
            let top = h + (middle - knobH) * p / max(1, maxPos)
            for y in top..<min(h + middle, top + knobH) { for x in (width - 8)..<(width - 3) { img[x, y] = TestPage.rgba(140, 140, 140) } }
        }
        if sidebarSpinner {
            let c = TestPage.rgba(UInt8(captures * 37 % 256), UInt8(captures * 91 % 256), 200)
            for y in (h + 200)..<(h + 240) { for x in (s - 24)..<(s - 16) { img[x, y] = c } }
        }
        if hoverCardEvery > 0 {
            let pointer = p + middle / 2
            let card = pointer / hoverCardEvery * hoverCardEvery
            if pointer - card < 64 {
                for r in 0..<middle where (card..<(card + 64)).contains(p + r) {
                    for x in (s + 20)..<(width - 20) { img[x, h + r] = Self.blend(img[x, h + r], TestPage.black, 0.2) }
                }
            }
        }
        if contentPatch && captures % 2 == 0 {
            // A blinking cursor that scrolls with the content (page rows 300..<316).
            for r in 0..<middle where (300..<316).contains(p + r) { for x in (s + 200)..<(s + 203) { img[x, h + r] = TestPage.black } }
        }
        return img
    }

    static func blend(_ p: UInt32, _ q: UInt32, _ a: Double) -> UInt32 {
        var out: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            let x = Double((p >> UInt32(shift)) & 0xFF), y = Double((q >> UInt32(shift)) & 0xFF)
            out |= UInt32((x * (1 - a) + y * a).rounded()) << UInt32(shift)
        }
        return out
    }

    func setScrollMethod(_ m: ScrollMethod) -> Bool {
        guard !unsupportedMethods.contains(m) else { return false }
        method = m
        if methodsTried.last != m { methodsTried.append(m) }
        return true
    }

    private func checkLoad() {
        guard let t = loadRequestedAt, clock - t >= loadDelay else { return }
        hiddenTop = max(0, hiddenTop - loadRows)
        loadRequestedAt = nil
    }

    func scroll(pixels: Int) async throws {
        scrolls += 1
        clock += 0.01
        if ignoredMethods.contains(method) { return }
        var pixels = pixels
        if let o = overshoot, overshootMethods.contains(method) {
            let k = o.lowerBound + (o.upperBound - o.lowerBound) * Double(rng.next() % 1000) / 999
            pixels = Int((Double(pixels) * k).rounded())
        }
        if pixels < 0 && pos == hiddenTop && hiddenTop > 0 && loadRequestedAt == nil { loadRequestedAt = clock }
        if let n = replaceContentAfterScrolls, scrolls == n {
            pageSeed &+= 1000
            page = TestPage.make(width: page.width, height: page.height, seed: pageSeed, firstIndex: 100_000)
        }
        var target = pos + (invertScroll ? -pixels : pixels)
        if jitter && pixels > 0 {
            let j = Int(rng.next() % 3) + 1
            target += rng.next() % 2 == 0 ? j : -j
        }
        if growStep > 0 && target > maxPos && page.height < growLimit {
            // Infinite scroll: more content loads when you reach the bottom.
            page = TestPage.make(width: page.width, height: min(growLimit, page.height + growStep), seed: pageSeed)
        }
        target = min(max(hiddenTop, target), maxPos)
        if smoothFrames > 0 && target != pos { anim = (pos, target, smoothFrames) }
        pos = target
    }

    func pause(milliseconds: Int) async { clock += Double(milliseconds) / 1000; checkLoad() }

    func reverseScrollDirection() { invertScroll.toggle() }

    private(set) var cancelled = false
    var isCancelled: Bool { cancelled }
    var now: Double { clock }

    // MARK: What a perfect capture would look like

    /// The ideal tall image for a capture that starts at page row `start` and runs to the end:
    /// header once, every content row once, the sidebar once (then its background), footer once.
    func expected(from start: Int, pageHeight: Int? = nil) -> PixelImage {
        let ph = pageHeight ?? page.height
        let contentRows = max(ph - start, middle)
        var out = PixelImage(width: width, height: h + contentRows + f, fill: TestPage.white)
        if let header { for y in 0..<h { for x in 0..<width { out[x, y] = header[x, y] } } }
        for r in 0..<contentRows {
            let py = start + r
            if py < ph { for x in 0..<page.width { out[s + x, h + r] = page[x, py] } }
            if let sidebar {
                for x in 0..<s {
                    // Columns that are one flat color stay as they are; detailed ones are filled.
                    out[x, h + r] = r < middle ? sidebar[x, r] : (Self.columnIsFlat(sidebar, x) ? sidebar[x, 0] : Self.sidebarBackground)
                }
            }
        }
        if let footer { for y in 0..<f { for x in 0..<width { out[x, h + contentRows + y] = footer[x, y] } } }
        return out
    }

    static func columnIsFlat(_ img: PixelImage, _ x: Int) -> Bool {
        (0..<img.height).allSatisfy { img[x, $0] == img[x, 0] }
    }
}

/// nil when the two images are identical; otherwise a short note on where they first differ.
func mismatch(_ a: PixelImage, _ b: PixelImage) -> String? {
    if a.width != b.width || a.height != b.height { return "size \(a.width)×\(a.height) vs \(b.width)×\(b.height)" }
    for y in 0..<a.height where a.row(y) != b.row(y) {
        let x = (0..<a.width).first { a[$0, y] != b[$0, y] } ?? 0
        return "first difference at row \(y), column \(x)"
    }
    return nil
}
