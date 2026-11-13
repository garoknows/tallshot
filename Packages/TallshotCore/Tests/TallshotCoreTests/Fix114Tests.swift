import Foundation
import Testing
import TallshotCore

/// Tests for 1.1.4: the self-test page's drawing area, and text that may be missing from a
/// scrolling capture's exports.

@Suite("1.1.4: the self-test page draws only its own rows")
struct SelfTestPageDrawingTests {
    let rows = 2400

    @Test("An area inside the page draws the rows it touches")
    func inside() {
        #expect(TestPage.rowsToDraw(minY: 100.5, maxY: 200.2, rows: rows) == 100..<201)
        #expect(TestPage.rowsToDraw(minY: 0, maxY: 2400, rows: rows) == 0..<2400)
    }

    @Test("An area across the top or bottom edge draws only the page's part")
    func acrossAnEdge() {
        #expect(TestPage.rowsToDraw(minY: -44, maxY: 30, rows: rows) == 0..<30)
        #expect(TestPage.rowsToDraw(minY: 2390, maxY: 2456, rows: rows) == 2390..<2400)
    }

    @Test("An area wholly above the page (the inset under the toolbar, or pulled down) draws nothing")
    func above() {
        #expect(TestPage.rowsToDraw(minY: -120, maxY: -44, rows: rows).isEmpty)
        #expect(TestPage.rowsToDraw(minY: -44, maxY: 0, rows: rows).isEmpty)
    }

    @Test("An area wholly below the page (the inset under the message box, or pulled up) draws nothing")
    func below() {
        #expect(TestPage.rowsToDraw(minY: 2410, maxY: 2456, rows: rows).isEmpty)
        #expect(TestPage.rowsToDraw(minY: 2400, maxY: 2456, rows: rows).isEmpty)
        #expect(TestPage.rowsToDraw(minY: 2401.5, maxY: 2402, rows: rows).isEmpty)
    }

    @Test("An empty area draws nothing")
    func emptyArea() {
        #expect(TestPage.rowsToDraw(minY: 500, maxY: 500, rows: rows).isEmpty)
    }

    @Test("Any area, anywhere, gives rows within the page (1.1.3 trapped on areas outside it)")
    func anyArea() {
        var rng = SplitMix(seed: 0x51F7_E57C)
        for _ in 0..<5_000 {
            let a = Double(Int(rng.next() % 3_000)) - 300 + Double(rng.next() % 100) / 100
            let b = a + Double(rng.next() % 700) + Double(rng.next() % 100) / 100
            let r = TestPage.rowsToDraw(minY: a, maxY: b, rows: rows)
            #expect(r.lowerBound >= 0 && r.upperBound <= rows, "area \(a)..<\(b) gave \(r)")
            #expect(r.isEmpty || (Double(r.lowerBound) < b && Double(r.upperBound) > a), "area \(a)..<\(b) gave \(r)")
        }
    }

    @Test("Label lines: none when nothing is drawn, one line of margin around what is")
    func labels() {
        #expect(TestPage.labelLines(for: 0..<0).isEmpty)
        #expect(TestPage.labelLines(for: 2400..<2400).isEmpty)
        #expect(TestPage.labelLines(for: 0..<30) == 0..<3)
        #expect(TestPage.labelLines(for: 2390..<2400) == 107..<111)
        #expect(TestPage.labelLines(for: 440..<460) == 19..<22)
    }
}

@Suite("1.1.4: text that may be missing from a scrolling capture")
struct TextReadingLogTests {
    @Test("No readings: nothing to say")
    func noReadings() {
        let log = TextReadingLog()
        #expect(!log.mayBeMissingText)
        #expect(log.note == nil)
    }

    @Test("Every reading complete: nothing is missing")
    func allComplete() {
        var log = TextReadingLog()
        for _ in 0..<5 { log.reading(cutShort: false) }
        log.finalReading(cutShort: false)
        #expect(log.readings == 5 && log.cutShort == 0)
        #expect(!log.mayBeMissingText)
        #expect(log.note == nil)
    }

    @Test("Only the last step's reading was cut short, and the longer final reading covered it")
    func lastCoveredByFinal() {
        var log = TextReadingLog()
        log.reading(cutShort: false); log.reading(cutShort: false); log.reading(cutShort: true)
        log.finalReading(cutShort: false)
        #expect(log.cutShort == 1)
        #expect(!log.mayBeMissingText)
    }

    @Test("An earlier reading was cut short: some text may be missing, and the note says how many")
    func earlierCutShort() throws {
        var log = TextReadingLog()
        log.reading(cutShort: false); log.reading(cutShort: true); log.reading(cutShort: false)
        log.finalReading(cutShort: false)
        #expect(log.mayBeMissingText)
        let note = try #require(log.note)
        #expect(note.contains("may be missing"))
        #expect(note.contains("1 of 3"))
        #expect(note.contains("image is complete"))
    }

    @Test("The final reading was cut short too: some text may be missing")
    func finalCutShort() {
        var log = TextReadingLog()
        log.reading(cutShort: false); log.reading(cutShort: true)
        log.finalReading(cutShort: true)
        #expect(log.mayBeMissingText)
    }

    @Test("No final reading (the capture ended another way): any cut-short reading counts")
    func noFinal() {
        var log = TextReadingLog()
        log.reading(cutShort: false); log.reading(cutShort: true)
        #expect(log.mayBeMissingText)
        var clean = TextReadingLog()
        clean.reading(cutShort: false)
        #expect(!clean.mayBeMissingText)
    }
}

@Suite("1.1.4: the Markdown file says so first")
struct MissingTextMarkdownTests {
    let doc = ExportDocument(blocks: [.paragraph([Inline("Quorvex plinth ledger.")])], source: .accessibility)

    @Test("With a missing-text note, the file's first line is the warning, before the image")
    func warningFirst() {
        var d = doc
        d.missingNote = "Some text may be missing: test note."
        let lines = Markdown.render(d, imageFile: "Capture.png").components(separatedBy: "\n")
        #expect(lines.first == "**Some text may be missing: test note.**")
        #expect(lines.contains("![Tallshot capture](<Capture.png>)"))
        #expect(lines.firstIndex(of: "![Tallshot capture](<Capture.png>)")! > 0)
        #expect(lines.contains("Quorvex plinth ledger."))
    }

    @Test("Without one, the file starts as before")
    func unchanged() {
        #expect(Markdown.render(doc, imageFile: "Capture.png").hasPrefix("![Tallshot capture](<Capture.png>)"))
        #expect(Markdown.render(doc).hasPrefix("_Text from the app's accessibility tree (exact text)._"))
    }
}
