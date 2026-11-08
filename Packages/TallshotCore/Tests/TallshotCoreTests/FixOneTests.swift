import CoreGraphics
import Foundation
import Testing
import TallshotCore

/// Tests for the browser and chat-app fixes (fix 01).

@Suite("Scroll events", .serialized)
@MainActor
struct ScrollEventTests {
    func phase(_ e: CGEvent) -> Int64 { e.getIntegerValueField(.scrollWheelEventScrollPhase) }

    @Test(arguments: [ScrollMethod.gesture, .wheelPixels, .wheelLines])
    func eventsCarryNoModifierKeys(method: ScrollMethod) throws {
        // The private source Tallshot uses, and no source at all. (A source that shares the
        // keyboard's state can't be created in a restricted sandbox: it waits forever.)
        for source in [ScrollEvents.privateSource(), nil] {
            let events = ScrollEvents.make(points: 700, at: CGPoint(x: 300, y: 200), inverted: false, method: method, source: source)
            #expect(!events.isEmpty)
            for e in events {
                #expect(e.flags.intersection(ModifierKeys.mask).isEmpty)
                #expect(e.flags.rawValue & 0xFFFF_0000 == 0)   // no device-independent modifier bits at all
                #expect(e.getIntegerValueField(.eventSourceUserData) == ScrollEvents.marker)
                #expect(e.location == CGPoint(x: 300, y: 200))
                #expect(e.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0)
            }
        }
    }

    @Test func gestureHasBeganChangedEnded() {
        let events = ScrollEvents.make(points: 700, at: .zero, inverted: false, method: .gesture)
        // 700 points in chunks of 240: 3 moving events, then a zero-delta Ended.
        #expect(events.count == 4)
        #expect(phase(events[0]) == Int64(CGScrollPhase.began.rawValue))
        #expect(events[1...2].allSatisfy { phase($0) == Int64(CGScrollPhase.changed.rawValue) })
        #expect(phase(events[3]) == Int64(CGScrollPhase.ended.rawValue))
        #expect(events[3].getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0)
        #expect(events.allSatisfy { $0.getIntegerValueField(.scrollWheelEventIsContinuous) == 1 })
        let total = events.map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) }.reduce(0, +)
        #expect(total == -700)   // negative: scrolls down the page
    }

    @Test func singleChunkGestureStillBeginsAndEnds() {
        let events = ScrollEvents.make(points: 100, at: .zero, inverted: false, method: .gesture)
        #expect(events.map(phase) == [Int64(CGScrollPhase.began.rawValue), Int64(CGScrollPhase.ended.rawValue)])
    }

    @Test func wheelFallbacksAreNotContinuousAndHaveNoPhase() {
        let px = ScrollEvents.make(points: -500, at: .zero, inverted: false, method: .wheelPixels)
        #expect(px.allSatisfy { $0.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 && phase($0) == 0 })
        #expect(px.map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) }.reduce(0, +) == 500)   // up
        let lines = ScrollEvents.make(points: 400, at: .zero, inverted: false, method: .wheelLines)
        #expect(lines.allSatisfy { $0.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 && phase($0) == 0 })
        #expect(lines.map { $0.getIntegerValueField(.scrollWheelEventDeltaAxis1) }.reduce(0, +) == -10)   // 400 / 40 lines
    }

    @Test func invertedFlipsDirection() {
        let e = ScrollEvents.make(points: 200, at: .zero, inverted: true, method: .wheelPixels)
        #expect(e[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 200)
    }
}

@Suite("Waiting for the hotkey's keys")
@MainActor
struct ModifierWaitTests {
    @Test func waitsUntilKeysAreReleased() async {
        var polls = 0, clock = 0.0
        let ok = await ModifierKeys.waitUntilReleased(
            flags: { polls += 1; return polls < 6 ? [.maskCommand, .maskShift, .maskControl, .maskAlternate] : [] },
            now: { clock }, sleep: { clock += Double($0) / 1000 })
        #expect(ok)
        #expect(polls == 6)
    }

    @Test func givesUpAfterTwoSeconds() async {
        var clock = 0.0
        let ok = await ModifierKeys.waitUntilReleased(flags: { .maskShift }, now: { clock }, sleep: { clock += Double($0) / 1000 })
        #expect(!ok)
        #expect(clock >= 2 && clock < 2.1)
    }

    @Test func capsLockIsNotAModifierToWaitFor() {
        #expect(!ModifierKeys.anyHeld(.maskAlphaShift))
        #expect(ModifierKeys.anyHeld(.maskSecondaryFn))
    }
}

@Suite("First step", .serialized)
@MainActor
struct FirstStepTests {
    @Test func ignoredGestureFallsBackToMouseWheel() async throws {
        // Like Chromium ignoring a gesture: the wheel fallback must take over, not "bottom".
        let w = SimulatedWindow(pageHeight: 2600, header: 40, footer: 40)
        w.ignoredMethods = [.gesture]
        let r = try await capture(w)
        #expect(r.reason == .bottom)
        #expect(r.scrollMethod == .wheelPixels)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }

    @Test func onlyLineScrollingWorks() async throws {
        let w = SimulatedWindow(pageHeight: 2600)
        w.ignoredMethods = [.gesture, .wheelPixels]
        let r = try await capture(w)
        #expect(r.scrollMethod == .wheelLines)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }

    @Test func areaThatNeverMovesSaysSo() async throws {
        let w = SimulatedWindow(pageHeight: 5000, header: 40)
        w.ignoredMethods = [.gesture, .wheelPixels, .wheelLines]
        let r = try await capture(w)
        #expect(r.reason == .didNotScroll)
        #expect(r.reason.isEarly)
        #expect(r.reason.headline == "This area didn't scroll")
        #expect(r.reason.note.contains("Point at the part that scrolls"))
        #expect(StopReason.allCasesEarly.allSatisfy { $0.headline != nil && !$0.note.isEmpty })
        #expect(StopReason.bottom.headline == nil)
        #expect(r.image == w.render(at: 0))   // one screen, kept
        #expect(w.methodsTried == [.gesture, .wheelPixels, .wheelLines])
    }

    @Test func fromTopWithIgnoredGestureStillStartsAtTheTop() async throws {
        let w = SimulatedWindow(pageHeight: 3000, start: 1400, footer: 50)
        w.ignoredMethods = [.gesture]
        let r = try await capture(w) { $0.fromTop = true }
        #expect(r.reason == .bottom)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }
}

@Suite("Fallback regions", .serialized)
@MainActor
struct CropTests {
    @Test func fallbackCaptureIsCroppedToTheColumnsThatMoved() async throws {
        let w = SimulatedWindow(width: 600, height: 400, pageHeight: 2400, header: 40, sidebar: 180)
        let r = try await capture(w) { $0.cropToMovingColumns = true }
        #expect(r.reason == .bottom)
        let keep = try #require(r.croppedColumns)
        // The sidebar (columns 0..<180) is gone, apart from a small margin.
        #expect(keep.lowerBound >= 160 && keep.lowerBound < 190)   // the sidebar's items end at column 172
        #expect(r.image.width == keep.count)
        #expect(mismatch(r.image, w.expected(from: 0).columns(keep)) == nil)
        let rep = BarcodeReport.read(r.image, originX: Double(180 - keep.lowerBound + TestPage.barcodeX),
                                     cellWidth: Double(TestPage.cellWidth), rows: w.h..<r.image.height)
        #expect(rep.isClean && rep.first == 0 && rep.last == 2399)
    }

    @Test func realScrollAreaIsNotCropped() async throws {
        let w = SimulatedWindow(width: 600, height: 400, pageHeight: 2400, sidebar: 180)
        let r = try await capture(w)
        #expect(r.croppedColumns == nil)
        #expect(r.image.width == 600)
    }
}

@Suite("Floating overlays", .serialized)
@MainActor
struct OverlayTests {
    /// The content part (above the final footer) must be the page, pixel for pixel, with no
    /// piece of an overlay in it; the bottom must be the last frame's overlay and footer, once.
    func check(_ w: SimulatedWindow, _ r: CaptureResult, bandAtLeast: Int) {
        #expect(r.reason == .bottom)
        #expect(r.footer >= w.f + bandAtLeast)
        let contentEnd = r.image.height - r.footer
        let ideal = w.expected(from: 0)
        #expect(mismatch(r.image.rows(0..<contentEnd), ideal.rows(0..<contentEnd)) == nil)
        let last = w.render(at: w.maxPos)
        #expect(mismatch(r.image.rows(contentEnd..<r.image.height), last.rows((w.height - r.footer)..<w.height)) == nil)
        // Every row of the page appears: the content plus what shows through the last overlay.
        #expect(contentEnd - w.h + r.footer >= w.page.height - w.maxPos)
        let v = BarcodeCheck.verdict(for: r.image, rows: r.header..<contentEnd)
        #expect(v?.passed == true)
        #expect(v?.report.first == 0)
    }

    @Test(arguments: [0.6, 0.8])
    func floatingChipsWithGaps(step: Double) async throws {
        let w = SimulatedWindow(width: 520, height: 500, pageHeight: 3200, header: 40, footer: 60)
        w.chipsBand = 34
        let r = try await capture(w) { $0.stepFraction = step }
        check(w, r, bandAtLeast: 34 - 6)
    }

    @Test func fadeGradientOverMovingText() async throws {
        let w = SimulatedWindow(width: 520, height: 500, pageHeight: 3200, header: 40, footer: 60)
        w.fadeBand = 40
        let r = try await capture(w)
        check(w, r, bandAtLeast: 40)
    }

    @Test func messageBoxWithSeeThroughMargin() async throws {
        let w = SimulatedWindow(width: 520, height: 500, pageHeight: 3200, header: 40, footer: 70)
        w.composerMargin = 14
        let r = try await capture(w)
        #expect(r.reason == .bottom)
        // The box and its see-through margin are one overlay band at the bottom.
        let contentEnd = r.image.height - r.footer
        #expect(mismatch(r.image.rows(0..<contentEnd), w.expected(from: 0).rows(0..<contentEnd)) == nil,
                "footer \(r.footer) height \(r.image.height) steps \(r.steps) \(mismatch(r.image.rows(0..<contentEnd), w.expected(from: 0).rows(0..<contentEnd)) ?? "")")
        #expect(BarcodeCheck.verdict(for: r.image, rows: r.header..<contentEnd)?.passed == true)
    }

    @Test func chatLayoutWithEverything() async throws {
        // An LLM chat: sticky header, fade, chips with gaps, a message box with margins, Retina size.
        let w = SimulatedWindow(width: 1000, height: 1400, pageHeight: 9000, header: 90, footer: 180)
        w.composerMargin = 30
        w.fadeBand = 70
        w.chipsBand = 60
        w.jitter = true
        let r = try await capture(w)
        #expect(r.reason == .bottom)
        let contentEnd = r.image.height - r.footer
        #expect(mismatch(r.image.rows(0..<contentEnd), w.expected(from: 0).rows(0..<contentEnd)) == nil)
        let v = BarcodeCheck.verdict(for: r.image, rows: r.header..<contentEnd)
        #expect(v?.passed == true)
        #expect(v?.report.first == 0)
    }
}

@Suite("Chat export from the top", .serialized)
@MainActor
struct ChatFromTopTests {
    @Test func olderMessagesLoadingAtTheTopAreIncluded() async throws {
        // 1,200 rows of older messages load 400 at a time, 0.8 s after reaching the top.
        let w = SimulatedWindow(pageHeight: 4000, start: 2000, footer: 50)
        w.hiddenTop = 1200
        let r = try await capture(w) { $0.fromTop = true }
        #expect(w.hiddenTop == 0)
        #expect(r.reason == .bottom)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
        #expect(report(r, w).first == 0)
    }

    @Test func slowLoadingIsWaitedFor() async throws {
        let w = SimulatedWindow(pageHeight: 3000, start: 900)
        w.hiddenTop = 600
        w.loadRows = 300
        w.loadDelay = 1.4
        let r = try await capture(w) { $0.fromTop = true }
        #expect(w.hiddenTop == 0)
        #expect(report(r, w).first == 0)
    }
}

@Suite("Barcode check")
struct BarcodeCheckTests {
    @Test(arguments: [1, 2])
    func findsBarcodesAnywhereAtAnyScale(scale: Int) {
        // A page whose barcode sits 137 px in, at 1x or 2x.
        let page = TestPage.make(width: 300, height: 600, firstIndex: 5000)
        var img = PixelImage(width: 600 * scale, height: 600 * scale, fill: TestPage.white)
        for y in 0..<(600 * scale) { for x in 0..<(300 * scale) { img[137 + x, y] = page[x / scale, y / scale] } }
        let v = BarcodeCheck.verdict(for: img)
        #expect(v?.passed == true)
        #expect(v?.report.first == 5000 && v?.report.last == 5599)
        #expect(v?.message == "Barcode check passed: rows 5,000 to 5,599 once each, in order.")
    }

    @Test func reportsRepeats() {
        let page = TestPage.make(width: 300, height: 600)
        let bad = PixelImage(width: 300, height: 700, pixels: page.rows(0..<400).pixels + page.rows(300..<600).pixels)
        let v = BarcodeCheck.verdict(for: bad)
        #expect(v?.passed == false)
        #expect(v?.message.hasPrefix("Barcode check failed") == true)
    }

    @Test func normalPicturesHaveNoVerdict() {
        // Text-like blocks and flat color, no barcodes.
        var img = PixelImage(width: 500, height: 400, fill: TestPage.white)
        var rng = SplitMix(seed: 9)
        for _ in 0..<300 {
            let x0 = Int(rng.next() % 460), y0 = Int(rng.next() % 390), w = 4 + Int(rng.next() % 30)
            for y in y0..<(y0 + 8) { for x in x0..<min(500, x0 + w) { img[x, y] = TestPage.black } }
        }
        #expect(BarcodeCheck.verdict(for: img) == nil)
        #expect(BarcodeCheck.verdict(for: PixelImage(width: 400, height: 300, fill: TestPage.rgba(30, 30, 30))) == nil)
    }
}

extension StopReason {
    static let allCasesEarly: [StopReason] = [.heightCap, .sizeCap, .timeCap, .cancelled, .lostTrack, .didNotScroll]
}

@Suite("Overshoot", .serialized)
@MainActor
struct OvershootTests {
    /// A scroll target with momentum: every request moves 2 to 4 times further, with a glide.
    func overshooting(_ w: SimulatedWindow) -> SimulatedWindow {
        w.overshoot = 2...4
        w.smoothFrames = 4
        return w
    }

    @Test(arguments: [UInt64(1), 7, 19, 33])
    func overshootingPageIsCompleteAndPixelExact(seed: UInt64) async throws {
        let w = overshooting(SimulatedWindow(width: 420, height: 500, pageHeight: 6000, seed: seed, header: 44, footer: 56))
        let r = try await capture(w) { $0.maxSeconds = 600 }
        #expect(r.reason == .bottom)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
        #expect(report(r, w).isClean && report(r, w).last == 5999)
    }

    @Test func overshootInABrowserLayoutStartsSmall() async throws {
        let w = overshooting(SimulatedWindow(width: 600, height: 700, pageHeight: 9000, header: 60, footer: 120, sidebar: 160))
        w.chipsBand = 40
        w.jitter = true
        let r = try await capture(w) { $0.cautiousStartFraction = 0.3; $0.cropToMovingColumns = true; $0.maxSeconds = 600 }
        #expect(r.reason == .bottom)
        let contentEnd = r.image.height - r.footer
        let keep = try #require(r.croppedColumns)
        #expect(mismatch(r.image.rows(0..<contentEnd), w.expected(from: 0).columns(keep).rows(0..<contentEnd)) == nil)
        #expect(BarcodeCheck.verdict(for: r.image, rows: r.header..<contentEnd)?.passed == true)
    }

    @Test func overshootFromTop() async throws {
        let w = overshooting(SimulatedWindow(pageHeight: 5000, start: 3000, footer: 50))
        let r = try await capture(w) { $0.fromTop = true; $0.maxSeconds = 600 }
        #expect(r.reason == .bottom)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }

    @Test func gestureWithMomentumIsSwappedForTheWheel() async throws {
        // Only the gesture has momentum: the loop should settle on the mouse wheel.
        let w = overshooting(SimulatedWindow(pageHeight: 6000, header: 40))
        w.overshootMethods = [.gesture]
        let r = try await capture(w) { $0.maxSeconds = 600 }
        #expect(r.reason == .bottom)
        #expect(r.scrollMethod == .wheelPixels)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }

    @Test func scrollBarIsPreferredWhenOffered() async throws {
        let w = SimulatedWindow(pageHeight: 3000)
        w.unsupportedMethods = []
        let r = try await capture(w)
        #expect(r.scrollMethod == .scrollBar)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }
}

@Suite("Diagnostics", .serialized)
@MainActor
struct DiagnosticsTests {
    @Test func offByDefaultKeepsNothing() async throws {
        let w = SimulatedWindow(pageHeight: 4000)
        w.replaceContentAfterScrolls = 3
        let r = try await capture(w)
        #expect(r.reason.isEarly)
        #expect(r.diagnostics == nil)
        #expect(CaptureOptions().keepDiagnostics == false)
    }

    @Test func onKeepsFramesAndTheStepLog() async throws {
        let w = SimulatedWindow(pageHeight: 4000)
        w.replaceContentAfterScrolls = 3
        let r = try await capture(w) { $0.keepDiagnostics = true }
        let d = try #require(r.diagnostics)
        #expect(!d.frames.isEmpty && d.frames.count <= 32)
        #expect(d.steps.contains { $0.outcome == "moved" && $0.measured != nil })
        #expect(d.steps.contains { $0.outcome == "uncertain" })
        let text = d.text(reason: r.reason, region: "10, 20, 360 x 400", appName: "Test App", result: r)
        #expect(text.contains("App: Test App") && text.contains("wanted px") && text.contains("Stopped: lostTrack"))
    }
}
