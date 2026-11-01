import Foundation
import Testing
import TallshotCore

@Suite("Light on the Mac", .serialized)
struct LightnessTests {
    /// Lining up two Retina-sized frames must take a small slice of the ~400 ms each scroll step
    /// gets, so a 10-screen page stays well under the 8-second target.
    @Test func lineUpIsFastAtRetinaSize() {
        let page = TestPage.make(width: 1600, height: 4000, seed: 8)
        let a = page.rows(0..<1800), b = page.rows(1437..<3237)
        let start = DispatchTime.now().uptimeNanoseconds
        var result: Alignment = .noMovement
        for _ in 0..<5 { result = FrameAligner().align(a, b, expected: 1440) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / 5
        if case .moved(let l) = result { #expect(l.offset == 1437 && l.header == 0 && l.footer == 0 && l.score == 1) } else { Issue.record("expected a move") }
        #if DEBUG
        let budget = 2_000.0   // unoptimized builds are ~10x slower; the app ships optimized
        #else
        let budget = 150.0
        #endif
        #expect(ms < budget, "one line-up took \(ms) ms")
    }

    /// The tall image grows by exactly the new rows; nothing else is kept per step.
    @Test func memoryIsTheImagePlusOneFrame() {
        let page = TestPage.make(width: 800, height: 6000, seed: 2)
        var s = Stitcher(first: page.rows(0..<1000))
        var top = 0
        while top + 1000 + 800 <= 6000 {
            top += 800
            s.add(page.rows(top..<(top + 1000)), layout: PairLayout(header: 0, footer: 0, offset: 800))
        }
        #expect(s.image.height == top + 1000)
        #expect(s.image.pixels.count == 800 * (top + 1000))
        #expect(s.image == page.rows(0..<(top + 1000)))
    }
}
