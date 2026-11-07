import Foundation
import Testing
@testable import TallshotCore

/// One test per bug found in the 1.0 review, on generated pages only.
@Suite("Bug hunt before 1.0", .serialized)
@MainActor
struct BugHuntTests {
    @Test func reversedScrollingIsFoundWhenStartingAtTheTop() async throws {
        let w = SimulatedWindow(pageHeight: 3000, start: 0)
        w.invertScroll = true
        let r = try await capture(w)
        #expect(r.reason == .bottom)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }

    @Test func atTheVeryEndTryingTheOtherDirectionPutsThePageBack() async throws {
        let w = SimulatedWindow(height: 400, pageHeight: 3000, start: 2600)
        let r = try await capture(w)
        #expect(r.reason == .didNotScroll)
        #expect(w.pos == 2600)
        #expect(mismatch(r.image, w.expected(from: 2600)) == nil)
    }

    @Test func scrollMethodsAreComparedFairly() async throws {
        // Both ways of scrolling overshoot the same: the first one is kept.
        let w = SimulatedWindow(pageHeight: 6000)
        w.overshoot = 1.8...1.8
        let r = try await capture(w) { $0.stepFraction = 0.3 }
        #expect(r.scrollMethod == .gesture)
        #expect(mismatch(r.image, w.expected(from: 0)) == nil)
    }

    @Test func framesOfDifferentSizesDoNotCrash() {
        let a = PixelImage(width: 40, height: 40, pixels: Array(repeating: 0xFF00_0000, count: 1600))
        let b = PixelImage(width: 40, height: 38, pixels: Array(repeating: 0xFF00_0000, count: 1520))
        #expect(FrameAligner().align(a, b) == .uncertain(bestScore: 0))
    }

    @Test func aTallImageIsNotCopiedOnEveryStep() {
        var image = PixelImage(width: 100, height: 10, pixels: Array(repeating: 0, count: 1000))
        let strip = PixelImage(width: 100, height: 30, pixels: Array(repeating: 1, count: 3000))
        var growths = 0, capacity = image.pixels.capacity
        for _ in 0..<1000 {
            image.reserveRows(30)
            image.appendRows(of: strip, 0..<30)
            if image.pixels.capacity != capacity { growths += 1; capacity = image.pixels.capacity }
        }
        #expect(image.height == 30_010)
        #expect(growths < 30, "grew \(growths) times")
    }

    // Markdown escaping.
    @Test func markdownEscapesHTMLAndNumberedStarts() {
        let doc = ExportDocument(blocks: [.paragraph([Inline("<img src=x onerror=alert(1)>")]), .paragraph([Inline("2024. Results")])], source: .accessibility)
        let md = Markdown.render(doc)
        #expect(md.contains("\\<img src=x onerror=alert(1)>"))
        #expect(md.contains("2024\\. Results"))
    }
    @Test func markdownKeepsOnlyWebLinksAndEncodesThem() {
        let doc = ExportDocument(blocks: [.paragraph([Inline("bad", link: "javascript:alert(1)"), Inline(" good", link: "https://example.com/a (b)")])], source: .accessibility)
        let md = Markdown.render(doc)
        #expect(!md.contains("javascript"))
        #expect(md.contains("[ good](https://example.com/a%20%28b%29)"))
    }
    @Test func markdownCodeFenceIsLongerThanAnyBackticksInside() {
        let doc = ExportDocument(blocks: [.code("a ``` b\n~~~\nc ```` d")], source: .accessibility)
        let md = Markdown.render(doc)
        #expect(md.contains("`````\na ``` b\n~~~\nc ```` d\n`````"))
    }

    // Scroll events go to the window on top at the scroll point.
    @Test func scrollPointMovesOffAWindowCoveringThePaneCenter() {
        let pane = CGRect(x: 0, y: 0, width: 400, height: 600)
        let cover = CGRect(x: 150, y: 250, width: 100, height: 100)   // over the pane's center
        let frames = [cover, pane], ids: [UInt32] = [9, 7]
        let center = CGPoint(x: 200, y: 300), pointed = CGPoint(x: 50, y: 50)
        #expect(WindowChoice.scrollPoint(preferred: center, probe: pointed, region: pane, frames: frames, ids: ids, target: 7) == pointed)
        // Nothing on top: the center stays.
        #expect(WindowChoice.scrollPoint(preferred: center, probe: pointed, region: pane, frames: [pane], ids: [7], target: 7) == center)
        // The pointer is covered too: no better place, keep the center.
        let both = [CGRect(x: 0, y: 0, width: 400, height: 400), pane]
        #expect(WindowChoice.scrollPoint(preferred: center, probe: pointed, region: pane, frames: both, ids: ids, target: 7) == center)
    }
}
