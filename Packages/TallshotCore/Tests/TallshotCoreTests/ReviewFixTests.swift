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
}
