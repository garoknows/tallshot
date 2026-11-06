import CoreGraphics
import Testing
import TallshotCore

/// Tests for pane-only capture, the document model and the settings checks (fix 02).

@Suite("Pane under the pointer")
struct PanePickerTests {
    // A window 1200 x 800 with a sidebar (0..<260), a main pane (260..<800) and a second split
    // pane (800..<1200), each its own scroll area, as an app like a notes or mail app lays out.
    let window = CGRect(x: 100, y: 100, width: 1200, height: 800)
    func pane(_ x: CGFloat, _ w: CGFloat) -> AXNode { AXNode(role: "AXScrollArea", frame: CGRect(x: 100 + x, y: 152, width: w, height: 748)) }
    var sidebar: AXNode { pane(0, 260) }
    var main: AXNode { pane(260, 540) }
    var split: AXNode { pane(800, 400) }
    func path(_ area: AXNode) -> [AXNode] {
        [AXNode(role: "AXStaticText", frame: CGRect(x: area.frame.minX + 20, y: 300, width: 100, height: 18)),
         AXNode(role: "AXGroup", frame: area.frame.insetBy(dx: 4, dy: 4)), area,
         AXNode(role: "AXSplitGroup", frame: window), AXNode(role: "AXWindow", frame: window)]
    }

    @Test func pointingAtEachPanePicksOnlyThatPane() {
        for area in [sidebar, main, split] {
            let pick = PanePicker.pick(path: path(area), window: window, mode: .pane)
            #expect(pick.kind == .scrollArea)
            #expect(pick.frame == area.frame)
        }
    }

    @Test func wholeWindowModeTakesTheWindow() {
        let pick = PanePicker.pick(path: path(main), window: window, mode: .window)
        #expect(pick.kind == .window && pick.frame == window)
    }

    @Test func browserColumnThatChromiumReportsAsAGroup() {
        // A web page with its own sidebar and an inner scrolling chat column (a plain group whose
        // content is much taller than its box), inside the browser's web area.
        let web = AXNode(role: "AXWebArea", frame: CGRect(x: 100, y: 190, width: 1200, height: 710))
        let column = AXNode(role: "AXGroup", frame: CGRect(x: 360, y: 242, width: 940, height: 658),
                            childrenFrame: CGRect(x: 360, y: -4000, width: 920, height: 9000))
        let text = AXNode(role: "AXStaticText", frame: CGRect(x: 500, y: 400, width: 300, height: 18))
        // Browsers put a scroll area for the whole page above the web area: the nearer column wins.
        let outer = AXNode(role: "AXScrollArea", frame: CGRect(x: 100, y: 190, width: 1200, height: 710))
        let path = [text, AXNode(role: "AXGroup", frame: CGRect(x: 380, y: 380, width: 600, height: 80)), column, web, outer]
        let pick = PanePicker.pick(path: path, window: window, mode: .pane)
        #expect(pick.kind == .scrollableWebElement)
        #expect(pick.frame == column.frame)
        // With the column not detectable, the page's scroll area above the web area is used.
        let flat = AXNode(role: "AXGroup", frame: column.frame)
        #expect(PanePicker.pick(path: [text, flat, web, outer], window: window, mode: .pane).frame == outer.frame)
        // Only the web area: the page without tabs and toolbar.
        let pick2 = PanePicker.pick(path: [text, web], window: window, mode: .pane)
        #expect(pick2.kind == .webArea && pick2.frame == web.frame)
        // Nothing usable: the window (cropped later to what moved).
        #expect(PanePicker.pick(path: [text], window: window, mode: .pane).kind == .window)
    }

    @Test func groupThatFitsItsBoxIsNotAScrollingColumn() {
        let box = AXNode(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 400, height: 400), childrenFrame: CGRect(x: 0, y: 0, width: 400, height: 410))
        #expect(!box.looksScrollable)
    }
}

@Suite("Split window capture", .serialized)
@MainActor
struct SplitWindowTests {
    /// A whole-window region with three panes side by side: only the one under the pointer
    /// scrolls, so the crop to moving columns keeps only that pane.
    @Test(arguments: [0, 1, 2])
    func onlyThePointedPaneIsCaptured(pointed: Int) async throws {
        let w = SplitWindow(pointed: pointed)
        var o = CaptureOptions()
        o.cropToMovingColumns = true
        let r = try await CaptureSession(driver: w, options: o).run()
        #expect(r.reason == .bottom)
        let keep = try #require(r.croppedColumns)
        let pane = w.panes[pointed]
        #expect(keep.lowerBound >= pane.lowerBound - 12 && keep.upperBound <= pane.upperBound + 12)
        for (i, other) in w.panes.enumerated() where i != pointed {
            #expect(keep.upperBound <= other.lowerBound + 12 || keep.lowerBound >= other.upperBound - 12)
        }
        let rep = BarcodeCheck.verdict(for: r.image)
        #expect(rep?.passed == true && rep?.report.first == 0)
    }
}

/// Three barcoded pages side by side in one window, separated by divider lines.
@MainActor
final class SplitWindow: CaptureDriver {
    let panes: [Range<Int>] = [0..<220, 222..<640, 642..<1000]
    let pages: [PixelImage]
    let pointed: Int
    var pos = 0
    let height = 500
    private var clock = 0.0
    init(pointed: Int) {
        self.pointed = pointed
        pages = panes.enumerated().map { TestPage.make(width: $0.element.count, height: 2400, seed: UInt64($0.offset + 3)) }
    }
    func captureFrame() async throws -> PixelImage {
        clock += 0.03
        var img = PixelImage(width: 1000, height: height, fill: TestPage.rgba(200, 200, 205))
        for (i, cols) in panes.enumerated() {
            let p = i == pointed ? pos : 0
            for y in 0..<height { for (k, x) in cols.enumerated() { img[x, y] = pages[i][k, p + y] } }
        }
        return img
    }
    func scroll(pixels: Int) async throws { clock += 0.01; pos = min(max(0, pos + pixels), 2400 - height) }
    func pause(milliseconds: Int) async { clock += Double(milliseconds) / 1000 }
    var isCancelled: Bool { false }
    var now: Double { clock }
}

@Suite("Hotkey warnings")
struct HotkeyConflictTests {
    typealias H = HotkeyConflicts
    @Test func refusedHotkeyIsNeverAcceptedSilently() {
        #expect(H.warning(keyCode: H.keyX, modifiers: H.hyper, registered: false, systemTaken: false, running: [])?.contains("refused") == true)
    }
    @Test func raycastHyperKeysAreNamed() {
        for key in [H.keyC, H.keyV, H.keyF, H.keyX] {
            let w = H.warning(keyCode: key, modifiers: H.hyper, registered: true, systemTaken: false, running: ["com.raycast.macos"])
            #expect(w?.contains("Raycast") == true)
        }
        // Not running: no warning for those.
        #expect(H.warning(keyCode: H.keyX, modifiers: H.hyper, registered: true, systemTaken: false, running: []) == nil)
        // Tallshot's own default (Hyper+T) and Hyper+Z are fine.
        #expect(H.warning(keyCode: 17, modifiers: H.hyper, registered: true, systemTaken: false, running: ["com.raycast.macos"]) == nil)
        #expect(H.warning(keyCode: 6, modifiers: H.hyper, registered: true, systemTaken: false, running: ["com.raycast.macos"]) == nil)
    }
    @Test func systemShortcutsAreNamed() {
        #expect(H.warning(keyCode: H.key4, modifiers: H.cmd | H.shift, registered: true, systemTaken: false, running: [])?.contains("screenshots") == true)
        #expect(H.warning(keyCode: 0, modifiers: H.cmd, registered: true, systemTaken: true, running: [])?.contains("Keyboard Shortcuts") == true)
    }
}

@Suite("Document text")
struct DocumentTests {
    @Test func markdownHasHeadingsNestedBulletsLinksAndCode() {
        let doc = ExportDocument(blocks: [
            .heading(level: 1, [Inline("Trip plan")]),
            .paragraph([Inline("See "), Inline("the map", link: "https://example.com/a map")]),
            .listItem(level: 0, ordered: false, [Inline("Pack")]),
            .listItem(level: 1, ordered: false, [Inline("Socks")]),
            .listItem(level: 0, ordered: true, [Inline("Leave")]),
            .heading(level: 2, [Inline("Code")]),
            .code("let x = 1\n  print(x)"),
        ], source: .accessibility)
        let md = Markdown.render(doc, imageFile: "Tallshot 2026-10-31 at 14.05.22.png")
        #expect(md.hasPrefix("![Tallshot capture](<Tallshot 2026-10-31 at 14.05.22.png>)\n"))
        #expect(md.contains("_Text from the app's accessibility tree (exact text)._"))
        #expect(md.contains("\n# Trip plan\n"))
        #expect(md.contains("See [the map](https://example.com/a%20map)"))
        #expect(md.contains("\n- Pack\n  - Socks\n1. Leave\n"))
        #expect(md.contains("\n## Code\n"))
        #expect(md.contains("```\nlet x = 1\n  print(x)\n```"))
    }

    @Test func mergerDropsWhatWasSeenBefore() {
        let all: [Block] = (0..<50).map { .paragraph([Inline("Paragraph \($0)")]) }
        var m = SnapshotMerger()
        // Overlapping windows of 12 blocks, moving by 8, with one window that starts above.
        var top = 0
        while top < 50 { m.add(Array(all[top..<min(50, top + 12)])); top += top == 16 ? 5 : 8 }
        #expect(m.blocks == all)
    }

    @Test func layoutReaderRebuildsStructure() {
        var y = 0.0
        func line(_ t: String, x: Double = 40, h: Double = 16, gap: Double = 8, shade: Bool = false) -> TextLine {
            defer { y += h + gap }
            return TextLine(text: t, x: x, y: y, width: Double(t.count) * h * 0.5, height: h, onShade: shade)
        }
        let lines = [
            line("Weekly notes", h: 34, gap: 14),
            line("This week we finished the export work and"),
            line("started on the settings.", gap: 20),
            line("• Ship the PDF export"),
            line("◦ Page breaks between lines", x: 70),
            line("• Write the docs", gap: 20),
            line("1. First numbered"),
            line("2. Second numbered", gap: 20),
            line("let pages = 3", x: 50, shade: true),
            line("print(pages)", x: 50, gap: 20, shade: true),
            line("Done.")
        ]
        let blocks = LayoutReader.blocks(from: lines)
        let expected: [Block] = [
            .heading(level: 1, [Inline("Weekly notes")]),
            .paragraph([Inline("This week we finished the export work and started on the settings.")]),
            .listItem(level: 0, ordered: false, [Inline("Ship the PDF export")]),
            .listItem(level: 1, ordered: false, [Inline("Page breaks between lines")]),
            .listItem(level: 0, ordered: false, [Inline("Write the docs")]),
            .listItem(level: 0, ordered: true, [Inline("First numbered")]),
            .listItem(level: 0, ordered: true, [Inline("Second numbered")]),
            .code("let pages = 3\nprint(pages)"),
            .paragraph([Inline("Done.")]),
        ]
        #expect(blocks == expected)
    }
}

@Suite("PDF page breaks")
struct PageBreakTests {
    @Test func breaksFallBetweenLinesOfText() {
        // Lines of text 14 rows tall every 22 rows, blank between them.
        let blank: (Int) -> Bool = { $0 % 22 < 4 || $0 % 22 >= 18 }
        let pages = PageBreaker.pages(height: 10_000, pageHeight: 1000, isBlank: blank)
        #expect(pages.first?.lowerBound == 0 && pages.last?.upperBound == 10_000)
        for (a, b) in zip(pages, pages.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
        for p in pages.dropLast() {
            #expect(p.count <= 1000 && p.count >= 850)
            #expect(blank(p.upperBound - 1) && blank(p.upperBound))   // cut inside a blank gap
        }
        #expect(pages.count == 11)
    }

    @Test func pageWithNoBlankRowsIsCutAtThePageHeight() {
        let pages = PageBreaker.pages(height: 2500, pageHeight: 1000) { _ in false }
        #expect(pages == [0..<1000, 1000..<2000, 2000..<2500])
    }

    @Test func blankRowsAreFound() {
        var img = PixelImage(width: 400, height: 10, fill: TestPage.white)
        for x in 10..<100 { img[x, 3] = TestPage.black }
        img[5, 6] = TestPage.black   // one stray pixel still counts as blank
        let b = PageBreaker.blankRows(img)
        #expect(b[3] == false && b[0] && b[6])
    }
}

/// Some apps draw backgrounds with a faint dither that stays put while the page scrolls and
/// changes every so many rows, so a scrolled row comes back one color level off.
@Suite("Faint dither that doesn't scroll")
struct ScreenFixedDitherTests {
    let width = 400, height = 1600, tile = 420

    /// A made-up page: rows of "text" in dark-background colors, with blank gaps.
    func page(rows: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0xFF19_1919, count: width * rows)
        for y in 0..<rows where y % 28 < 16 {
            for x in 30..<370 {
                let v = (x &* 31 &+ (y / 28) &* 977 &+ (y % 28) &* 13) % 97
                if v < 30 { out[y * width + x] = 0xFFEE_EEEE - UInt32(v) &* 0x0001_0101 }
            }
        }
        return out
    }

    /// One screen of the page, with a pattern one level deep whose phase depends on the screen tile.
    func frame(_ page: [UInt32], at top: Int) -> PixelImage {
        var px = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            let phase = 1 + (y / tile) * 3
            for x in 0..<width {
                var v = page[(top + y) * width + x]
                if (x + phase) % 8 == 0 && (y + phase) % 4 == 0 { v -= 0x0001_0101 }
                px[y * width + x] = v
            }
        }
        return PixelImage(width: width, height: height, pixels: px)
    }

    @Test(arguments: [40, 200, 600]) func linesUpAcrossTheDitherLines(distance: Int) {
        let p = page(rows: height + 800)
        guard case .moved(let layout) = FrameAligner().align(frame(p, at: 0), frame(p, at: distance), expected: distance) else {
            Issue.record("should line up"); return
        }
        #expect(layout.offset == distance)
    }

    @Test func exactMatchingAloneCannotLineThemUp() {
        var strict = AlignmentParameters(); strict.nearMatchLevels = 0
        let p = page(rows: height + 800)
        guard case .uncertain = FrameAligner(parameters: strict).align(frame(p, at: 0), frame(p, at: 600), expected: 600) else {
            Issue.record("this test no longer reproduces the problem"); return
        }
    }

    /// The chat scrolls behind a see-through title bar, over a message box at the bottom.
    @Test(arguments: [200, 600, 1000]) func linesUpBehindATitleBarAndOverAMessageBox(distance: Int) {
        func covered(_ f: PixelImage, top: Int) -> PixelImage {
            var px = f.pixels
            for y in 0..<80 { for x in 0..<width { px[y * width + x] = ((px[y * width + x] >> 2) & 0x003F_3F3F) | 0xFF20_2020 } }
            for y in (height - 260)..<height { for x in 60..<340 where (x + y) % 3 != 0 { px[y * width + x] = 0xFF30_3030 + UInt32(y - height + 260) % 7 } }
            return PixelImage(width: width, height: height, pixels: px)
        }
        let p = page(rows: height + 1200)
        let a = covered(frame(p, at: 0), top: 0), b = covered(frame(p, at: distance), top: distance)
        guard case .moved(let layout) = FrameAligner().align(a, b, expected: distance) else {
            Issue.record("should line up"); return
        }
        #expect(layout.offset == distance)
    }

    @Test func aRealChangeIsStillRefused() {
        let p = page(rows: height + 800)
        var changed = p
        // Every text pixel in the new frame differs by more than the allowance.
        for i in changed.indices where changed[i] != 0xFF19_1919 { changed[i] -= 0x0010_1010 }
        guard case .uncertain = FrameAligner().align(frame(p, at: 0), frame(changed, at: 200), expected: 200) else {
            Issue.record("a visible change must not count as a match"); return
        }
    }

    @Test func fullWindowScrollAreaIsNotAPane() {
        let window = CGRect(x: 768, y: 33, width: 960, height: 1028)
        #expect(PanePicker.scrollAreaFillsWindow(window, window: window))
        #expect(!PanePicker.scrollAreaFillsWindow(CGRect(x: 1032, y: 33, width: 696, height: 1028), window: window))
    }
}

/// The element under the scroll point changes when hovered, so a frame that lit up a card never
/// matches the frames after it exactly.
@Suite("A card that lights up under the scroll point", .serialized)
@MainActor
struct HoverCardTests {
    func hovering() -> SimulatedWindow {
        let w = SimulatedWindow(width: 600, height: 700, pageHeight: 6000, footer: 80)
        w.hoverCardEvery = 300
        return w
    }

    func run(_ w: SimulatedWindow, parameters: AlignmentParameters = AlignmentParameters()) async throws -> CaptureResult {
        var o = CaptureOptions()
        o.cautiousStartFraction = 0.3
        o.maxSeconds = 600
        return try await CaptureSession(driver: w, options: o, aligner: FrameAligner(parameters: parameters)).run()
    }

    /// Reaching the bottom also proves the end is recognized with the sidebar still blinking.
    @Test func aBlinkingSidebarDoesNotStopTheCapture() async throws {
        let w = SimulatedWindow(width: 800, height: 700, pageHeight: 6000, footer: 80, sidebar: 200)
        w.sidebarSpinner = true
        let r = try await run(w)
        #expect(r.reason == .bottom)
        #expect(r.image.height == w.expected(from: 0).height)
    }

    @Test func wholePageIsCaptured() async throws {
        let w = hovering()
        let r = try await run(w)
        #expect(r.reason == .bottom)
        #expect(r.image.height == w.expected(from: 0).height)
    }

    @Test func gettingLostDoesNotLoopUntilTheTimeLimit() async throws {
        var strict = AlignmentParameters()
        strict.maxChangedBlockFraction = 0
        strict.nearMatchLevels = 0
        let w = hovering()
        let r = try await run(w, parameters: strict)
        #expect(r.reason != .bottom, "this test no longer reproduces the problem")
        #expect(r.reason != .timeCap)
        #expect(w.scrolls < 120)
    }

    @Test func aWholeDifferentPageIsStillRefused() {
        let a = SimulatedWindow(width: 600, height: 700, pageHeight: 6000, seed: 1)
        let b = SimulatedWindow(width: 600, height: 700, pageHeight: 6000, seed: 2)
        guard case .uncertain = FrameAligner().align(a.render(at: 0), b.render(at: 200), expected: 200) else {
            Issue.record("different content must not line up"); return
        }
    }
}

@Suite("Which window a capture is for")
struct WindowChoiceTests {
    // Front to back: a chat window on the left, a mail window behind it reaching further right.
    let frames = [CGRect(x: 0, y: 30, width: 864, height: 989), CGRect(x: 215, y: 30, width: 1396, height: 987)]
    let chat: Int32 = 10, mail: Int32 = 20, tallshot: Int32 = 30
    var owners: [Int32] { [chat, mail] }

    @Test func theMenuUsesTheFrontWindowNotWhateverIsBehindTheMenu() {
        #expect(WindowChoice.index(frames: frames, owners: owners, pointer: nil, front: chat, own: tallshot) == 0)
    }

    @Test func theHotkeyUsesTheWindowUnderThePointer() {
        let overMailOnly = CGPoint(x: 1200, y: 90)
        #expect(WindowChoice.index(frames: frames, owners: owners, pointer: overMailOnly, front: chat, own: tallshot) == 1)
        let overBoth = CGPoint(x: 500, y: 90)
        #expect(WindowChoice.index(frames: frames, owners: owners, pointer: overBoth, front: chat, own: tallshot) == 0)
    }

    @Test func overNoWindowUsesTheFrontApp() {
        #expect(WindowChoice.index(frames: frames, owners: owners, pointer: CGPoint(x: 1700, y: 10), front: mail, own: tallshot) == 1)
    }

    @Test func tallshotInFrontFallsBackToTheNextWindow() {
        let withOwn = [CGRect(x: 0, y: 0, width: 400, height: 400)] + frames
        #expect(WindowChoice.index(frames: withOwn, owners: [tallshot, chat, mail], pointer: nil, front: tallshot, own: tallshot) == 1)
    }

    @Test func noWindowsMeansNothing() {
        #expect(WindowChoice.index(frames: [], owners: [], pointer: nil, front: chat, own: tallshot) == nil)
    }
}

