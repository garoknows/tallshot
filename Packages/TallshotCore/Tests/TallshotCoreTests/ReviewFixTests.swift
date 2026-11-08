import Foundation
import Testing
@testable import TallshotCore

/// One test (or more) per finding of the November 2026 review, on generated data only.
@Suite("November 2026 review fixes", .serialized)
@MainActor
struct ReviewFixTests {
    // Finding 4: stitching must not copy the whole tall image on every step.
    @Test func stitchingManyStepsGrowsTheImageOnlyAFewTimes() {
        let w = 200, h = 100
        func frame(_ n: Int) -> PixelImage {
            PixelImage(width: w, height: h, pixels: (0..<(w * h)).map { UInt32(truncatingIfNeeded: $0 &* 2_654_435_761 &+ n) })
        }
        var stitcher = Stitcher(first: frame(0))
        var growths = 0, capacity = stitcher.image.pixels.capacity
        let layout = PairLayout(header: 10, footer: 20, offset: 60)
        for n in 1...300 {
            stitcher.add(frame(n), layout: layout)
            let c = stitcher.image.pixels.capacity
            if c != capacity { growths += 1; capacity = c }
        }
        #expect(stitcher.image.height == h + 300 * 60)
        // Growing by half again each time needs about log1.5(18_100 / 100) ≈ 13 growths;
        // growing to exactly what's needed would grow (and copy everything) 300 times.
        #expect(growths <= 20, "the tall image grew \(growths) times in 300 steps")
    }

    // Finding 5: a wide, tall capture must stop at a total pixel budget, not only a height.
    @Test func aWideCaptureStopsAtThePixelBudget() async throws {
        let w = SimulatedWindow(width: 360, height: 400, pageHeight: 12_000)
        let budget = 360 * 3_000
        let r = try await capture(w) { $0.maxHeight = 50_000; $0.maxPixels = budget }
        #expect(r.reason == .sizeCap)
        #expect(r.reason.isEarly)
        #expect(r.reason.headline == "Stopped at the size limit")
        #expect(r.image.width * r.image.height <= budget)
        #expect(r.image.height == 3_000)
        #expect(mismatch(r.image, w.expected(from: 0).rows(0..<3_000)) == nil)
    }

    @Test func theHeightLimitStillWinsWhenItIsLower() async throws {
        let w = SimulatedWindow(width: 360, height: 400, pageHeight: 12_000)
        let r = try await capture(w) { $0.maxHeight = 2_000; $0.maxPixels = 360 * 5_000 }
        #expect(r.reason == .heightCap)
        #expect(r.image.height == 2_000)
    }

    @Test func theDefaultBudgetKeepsAFullRetinaWidthUnderOneGigabyte() {
        // A 16-inch MacBook Pro screen is 3456 pixels wide at its default Retina scale.
        let o = CaptureOptions()
        let bytes = o.maxPixels * 4
        #expect(bytes <= 200_000_000)
        #expect(o.maxPixels / 3456 >= 14_000)
    }

    // Sweep: an app that offers a scroll bar but ignores it. Capture from Top must still start at
    // the top, not wherever the page was.
    @Test func fromTopStillStartsAtTheTopWhenTheScrollBarIsIgnored() async throws {
        let w = SimulatedWindow(pageHeight: 3000, start: 1200)
        w.unsupportedMethods = []
        w.ignoredMethods = [.scrollBar]
        let r = try await capture(w) { $0.fromTop = true }
        #expect(r.reason == .bottom)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil, "height \(r.image.height)")
    }

    // Sweep: after one overshoot, walking back must not depend on a way of scrolling that was
    // never shown to work in this app.
    @Test func anOvershootDoesNotStrandTheCaptureOnAnIgnoredScrollMethod() async throws {
        let w = SimulatedWindow(pageHeight: 6000)
        w.overshoot = 3.0...4.0
        w.overshootMethods = [.gesture]
        w.ignoredMethods = [.wheelPixels]
        let r = try await capture(w) { $0.maxSeconds = 600 }
        #expect(r.reason == .bottom, "stopped: \(r.reason), \(r.image.height) px")
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }
}
