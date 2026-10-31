import Testing
import TallshotCore

/// The layouts every pixel-exact test runs against.
struct Layout: CustomTestStringConvertible, Sendable {
    var header = 0, footer = 0, sidebar = 0, jitter = false
    var testDescription: String { "header \(header), footer \(footer), sidebar \(sidebar)\(jitter ? ", jitter" : "")" }
    static let all: [Layout] = [
        Layout(),
        Layout(header: 44),
        Layout(footer: 56),
        Layout(sidebar: 70),
        Layout(header: 44, footer: 56, sidebar: 70),
        Layout(jitter: true),
        Layout(header: 30, footer: 40, sidebar: 60, jitter: true),
    ]
}

@MainActor
func capture(_ w: SimulatedWindow, _ configure: (inout CaptureOptions) -> Void = { _ in }) async throws -> CaptureResult {
    var o = CaptureOptions()
    configure(&o)
    return try await CaptureSession(driver: w, options: o).run()
}

/// Where the barcode is in a capture of `w`.
@MainActor func report(_ r: CaptureResult, _ w: SimulatedWindow) -> BarcodeReport {
    BarcodeReport.read(r.image, originX: Double(w.s + TestPage.barcodeX), cellWidth: Double(TestPage.cellWidth),
                       rows: w.h..<(r.image.height - w.f))
}

@Suite("Stitching: pixel-exact", .serialized)
@MainActor
struct PixelExactTests {
    @Test(arguments: Layout.all, [0.35, 0.6, 0.8, 0.95])
    func wholePageIsPixelExact(layout: Layout, step: Double) async throws {
        let w = SimulatedWindow(pageHeight: 2600, seed: 3, header: layout.header, footer: layout.footer, sidebar: layout.sidebar)
        w.jitter = layout.jitter
        let r = try await capture(w) { $0.stepFraction = step }
        #expect(r.reason == .bottom)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
        #expect(report(r, w).isClean)
    }

    @Test(arguments: [UInt64(5), 11, 23, 47])
    func manySeedsAndPageHeights(seed: UInt64) async throws {
        let ph = 1200 + Int(seed % 7) * 517
        let w = SimulatedWindow(width: 300 + Int(seed % 3) * 70, height: 320 + Int(seed % 4) * 60, pageHeight: ph, seed: seed,
                                header: Int(seed % 2) * 36, footer: Int(seed % 3) * 20, sidebar: Int(seed % 2) * 50)
        w.jitter = true
        let r = try await capture(w)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }

    @Test func startsFromCurrentPosition() async throws {
        let w = SimulatedWindow(pageHeight: 3000, start: 777, header: 40)
        let r = try await capture(w)
        #expect(mismatch(r.image, w.expected(from: 777)) == nil)
        #expect(report(r, w).first == 777)
    }

    @Test func captureFromTopScrollsUpFirst() async throws {
        let w = SimulatedWindow(pageHeight: 3000, start: 1500, footer: 50)
        let r = try await capture(w) { $0.fromTop = true }
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
        #expect(report(r, w).first == 0)
    }

    @Test func smoothScrollingSettlesBeforeCapture() async throws {
        let w = SimulatedWindow(pageHeight: 2400, header: 40, footer: 40)
        w.smoothFrames = 4
        let r = try await capture(w)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }

    @Test func retinaSizedFrames() async throws {
        // A 2x screen: twice the pixels in each direction.
        let w = SimulatedWindow(width: 1400, height: 1600, pageHeight: 9000, header: 100, footer: 120, sidebar: 240)
        w.jitter = true
        let r = try await capture(w)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }
}

@Suite("Stitching: animation and low confidence", .serialized)
@MainActor
struct RobustnessTests {
    @Test func blinkingPatchFixedOnScreenDoesNotBreakLineUp() async throws {
        let w = SimulatedWindow(pageHeight: 2600, header: 40)
        w.fixedPatch = true
        let r = try await capture(w)
        #expect(r.reason == .bottom)
        #expect(r.image.height == w.expected(from: 0).height)
        #expect(report(r, w).isClean)
        #expect(report(r, w).first == 0 && report(r, w).last == 2599)
    }

    @Test func blinkingCursorInContentDoesNotBreakLineUp() async throws {
        let w = SimulatedWindow(pageHeight: 2600, footer: 50)
        w.contentPatch = true
        let r = try await capture(w)
        #expect(r.reason == .bottom)
        #expect(r.image.height == w.expected(from: 0).height)
        #expect(report(r, w).isClean)
    }

    @Test func transientOverlayIsRetriedNotGuessed() async throws {
        let w = SimulatedWindow(pageHeight: 2600, header: 40)
        // A popup covers the window for several captures in a row right after the second scroll.
        w.overlayCaptures = Set(8...14)
        let r = try await capture(w)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }

    @Test func contentThatCannotBeLinedUpStopsAndKeepsWhatIsSafe() async throws {
        let w = SimulatedWindow(pageHeight: 4000)
        w.replaceContentAfterScrolls = 3   // the page is swapped for an unrelated one mid-capture
        let ideal = w.expected(from: 0)
        let r = try await capture(w)
        #expect(r.reason == .lostTrack)
        #expect(r.reason.isEarly)
        let rep = report(r, w)
        #expect(rep.isClean)
        #expect(rep.first == 0)
        // Nothing from the unrelated page made it in.
        #expect((rep.last ?? 0) < 100_000)
        #expect(mismatch(r.image, ideal.rows(0..<r.image.height)) == nil)
    }

    @Test func alignerReportsUncertainForUnrelatedFrames() {
        let a = TestPage.make(width: 300, height: 400, seed: 1)
        let b = TestPage.make(width: 300, height: 400, seed: 2, firstIndex: 50_000)
        if case .uncertain = FrameAligner().align(a, b, expected: 300) {} else { Issue.record("expected uncertain") }
    }

    @Test func alignerFindsExactOffsetAndBands() {
        let page = TestPage.make(width: 300, height: 1200, seed: 4)
        let a = page.rows(100..<500), b = page.rows(417..<817)
        #expect(FrameAligner().align(a, b, expected: 300) == .moved(PairLayout(header: 0, footer: 0, offset: 317, score: 1)))
        #expect(FrameAligner().align(a, a) == .noMovement)
    }
}

@Suite("Stitching: bottom and caps", .serialized)
@MainActor
struct BottomTests {
    @Test func shortPageThatDoesNotScroll() async throws {
        let w = SimulatedWindow(height: 400, pageHeight: 250, header: 30)
        let r = try await capture(w)
        #expect(r.reason == .bottom)
        #expect(r.steps == 0)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }

    @Test func pageAFewRowsTallerThanTheWindow() async throws {
        let w = SimulatedWindow(height: 400, pageHeight: 437)
        let r = try await capture(w)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }

    @Test(arguments: [2, 3, 7])
    func pageThatIsAnExactMultipleOfTheStep(multiple: Int) async throws {
        // Window 400, no bands: first step 200, then 320. Make the scrollable distance land exactly.
        let ph = 400 + 200 + 320 * (multiple - 1)
        let w = SimulatedWindow(height: 400, pageHeight: ph)
        let r = try await capture(w)
        #expect(r.reason == .bottom)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }

    @Test func growingPageStopsAtHeightCap() async throws {
        let w = SimulatedWindow(height: 400, pageHeight: 1500)
        w.growStep = 1000
        w.growLimit = 200_000
        let r = try await capture(w) { $0.maxHeight = 6000 }
        #expect(r.reason == .heightCap)
        #expect(r.image.height == 6000)
        #expect(mismatch(r.image, w.expected(from: 0).rows(0..<6000)) == nil)
    }

    @Test func growingPageThatStopsGrowingEndsAtItsBottom() async throws {
        let w = SimulatedWindow(height: 400, pageHeight: 1500, footer: 40)
        w.growStep = 700
        w.growLimit = 3600
        let r = try await capture(w)
        #expect(r.reason == .bottom)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }

    @Test func timeCapStopsALongCapture() async throws {
        let w = SimulatedWindow(height: 400, pageHeight: 50_000)
        let r = try await capture(w) { $0.maxSeconds = 2; $0.maxHeight = 100_000 }
        #expect(r.reason == .timeCap)
        #expect(report(r, w).isClean)
        #expect(mismatch(r.image, w.expected(from: 0).rows(0..<r.image.height)) == nil)
    }

    @Test func cancelKeepsWhatWasCaptured() async throws {
        let w = SimulatedWindow(height: 400, pageHeight: 10_000, header: 40)
        w.cancelAfterCaptures = 12
        let r = try await capture(w)
        #expect(r.reason == .cancelled)
        #expect(r.image.height > 400)
        #expect(report(r, w).isClean)
        #expect(mismatch(r.image, w.expected(from: 0).rows(0..<r.image.height)) == nil)
    }
}

@Suite("Barcodes")
struct BarcodeTests {
    @Test func roundTrip() {
        let page = TestPage.make(width: 200, height: 5000, firstIndex: 123_000)
        for y in stride(from: 0, to: 5000, by: 7) {
            #expect(Barcode.decode(page, row: y, originX: 4, cellWidth: 4) == 123_000 + y)
        }
    }

    @Test func corruptedRowIsRejected() {
        var page = TestPage.make(width: 200, height: 10)
        // Flip one cell in row 5.
        let x = TestPage.barcodeX + 10 * TestPage.cellWidth + 1
        for xx in x..<(x + 2) { page[xx, 5] = page[xx, 5] == TestPage.black ? TestPage.white : TestPage.black }
        #expect(Barcode.decode(page, row: 5, originX: 4, cellWidth: 4) == nil)
    }

    @Test func reportFindsRepeatsAndGaps() {
        let page = TestPage.make(width: 200, height: 300)
        var img = page.rows(0..<100)
        let rest = page.rows(90..<300)   // rows 90..99 repeated
        var combined = PixelImage(width: 200, height: 0, pixels: [])
        combined = PixelImage(width: 200, height: img.height + rest.height, pixels: img.pixels + rest.pixels)
        #expect(!BarcodeReport.read(combined, originX: 4, cellWidth: 4).isClean)
        #expect(BarcodeReport.read(combined, originX: 4, cellWidth: 4).outOfOrder == 1)
        img = PixelImage(width: 200, height: 150, pixels: page.rows(0..<100).pixels + page.rows(150..<200).pixels)
        #expect(BarcodeReport.read(img, originX: 4, cellWidth: 4).missing.count == 50)
        #expect(BarcodeReport.read(page, originX: 4, cellWidth: 4).isClean)
    }

    @Test func retinaRowsCountAsOne() {
        let page = TestPage.make(width: 200, height: 50)
        var px: [UInt32] = []
        for y in 0..<50 { px += Array(page.row(y)); px += Array(page.row(y)) }
        let doubled = PixelImage(width: 200, height: 100, pixels: px)
        #expect(BarcodeReport.read(doubled, originX: 4, cellWidth: 4, pixelsPerRow: 2).isClean)
        #expect(!BarcodeReport.read(doubled, originX: 4, cellWidth: 4, pixelsPerRow: 1).isClean)
    }
}
