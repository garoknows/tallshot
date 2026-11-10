import AppKit
import Testing
import TallshotCore

/// A long document whose every point row carries its row number as a barcode, plus real text
/// drawn by AppKit, so the harness exercises real font rendering and not just flat blocks.
final class BarcodeDocument: NSView {
    let rows: Int
    init(width: CGFloat, rows: Int) {
        self.rows = rows
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(rows)))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirty: NSRect) {
        NSColor.white.setFill()
        dirty.fill()
        let first = max(0, Int(dirty.minY)), last = min(rows, Int(dirty.maxY.rounded(.up)))
        NSColor.black.setFill()
        for y in first..<last {
            for (c, dark) in Barcode.cells(for: y).enumerated() where dark {
                NSRect(x: CGFloat(TestPage.barcodeX + c * TestPage.cellWidth), y: CGFloat(y), width: CGFloat(TestPage.cellWidth), height: 1).fill()
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.25, alpha: 1)]
        let textX = CGFloat(TestPage.barcodeX + TestPage.barcodeWidth + 12)
        for line in (first / 22)...(last / 22 + 1) {
            let s = "Row \(line): the quick brown fox jumps over the lazy dog \(line * 7919 % 1000)" as NSString
            s.draw(at: NSPoint(x: textX, y: CGFloat(line * 22 + 3)), withAttributes: attrs)
        }
    }
}

/// A plain colored bar with a label: a sticky toolbar or a chat input box.
final class Bar: NSView {
    let color: NSColor, label: String
    init(color: NSColor, label: String) { self.color = color; self.label = label; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirty: NSRect) {
        color.setFill(); bounds.fill()
        (label as NSString).draw(at: NSPoint(x: 12, y: 8), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white])
    }
}

/// Action chips floating over the bottom of the text, with see-through gaps, and a fade from
/// clear to white behind them: the floating overlay band of an LLM chat.
final class FloatingChips: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirty: NSRect) {
        let fade = NSGradient(starting: NSColor.white.withAlphaComponent(0), ending: NSColor.white.withAlphaComponent(0.9))
        fade?.draw(in: bounds, angle: -90)
        NSColor(red: 0.88, green: 0.91, blue: 0.98, alpha: 1).setFill()
        for x in stride(from: 150.0, to: bounds.width - 70, by: 90) {
            NSBezierPath(roundedRect: NSRect(x: x, y: 6, width: 64, height: 22), xRadius: 11, yRadius: 11).fill()
        }
    }
}

/// An offscreen window holding a real NSScrollView, with an optional toolbar above it and an
/// input box below it. It renders itself into pixel buffers and scrolls when asked.
@MainActor
final class OffscreenScrollWindow: CaptureDriver {
    let window: NSWindow
    let container: NSView
    let scrollView: NSScrollView
    let document: BarcodeDocument
    let header: Bar?, footer: Bar?
    let scale: Int
    private(set) var clock = 0.0
    var isCancelled: Bool { false }
    var now: Double { clock }

    /// Each scroll request moves this many times further (momentum).
    var overshoot: CGFloat = 1
    let chips: FloatingChips?

    init(width: CGFloat = 420, height: CGFloat = 520, rows: Int = 4000, header: CGFloat = 0, footer: CGFloat = 0, scale: Int = 1, start: CGFloat = 0,
         chips: CGFloat = 0) {
        self.scale = scale
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        container = NSView(frame: frame)
        window.contentView = container
        scrollView = NSScrollView(frame: NSRect(x: 0, y: footer, width: width, height: height - header - footer))
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        document = BarcodeDocument(width: width, rows: rows)
        scrollView.documentView = document
        container.addSubview(scrollView)
        self.header = header > 0 ? Bar(color: NSColor(red: 0.18, green: 0.42, blue: 1, alpha: 1), label: "Sticky toolbar") : nil
        self.footer = footer > 0 ? Bar(color: NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1), label: "Message input box") : nil
        if let h = self.header { h.frame = NSRect(x: 0, y: height - header, width: width, height: header); container.addSubview(h) }
        if let f = self.footer { f.frame = NSRect(x: 0, y: 0, width: width, height: footer); container.addSubview(f) }
        if chips > 0 {
            let c = FloatingChips(frame: NSRect(x: 0, y: footer, width: width, height: chips))
            container.addSubview(c)
            self.chips = c
        } else {
            self.chips = nil
        }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: start))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    var maxScroll: CGFloat { document.frame.height - scrollView.contentView.bounds.height }

    func captureFrame() async throws -> PixelImage {
        clock += 0.03
        return Self.render(container, scale: scale)
    }

    func scroll(pixels: Int) async throws {
        clock += 0.01
        // Momentum lands on whole screen pixels, as real apps do.
        let points = (CGFloat(pixels) * overshoot).rounded() / CGFloat(scale)
        let y = min(max(0, scrollView.contentView.bounds.origin.y + points), maxScroll)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func pause(milliseconds: Int) async { clock += Double(milliseconds) / 1000 }

    /// Draws a view into a fresh RGBA buffer at the given scale.
    static func render(_ view: NSView, scale: Int) -> PixelImage {
        let size = view.bounds.size
        let w = Int(size.width) * scale, h = Int(size.height) * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        var pixels = [UInt32](repeating: 0, count: w * h)
        let data = rep.bitmapData!
        pixels.withUnsafeMutableBytes { dst in
            for y in 0..<h { memcpy(dst.baseAddress! + y * w * 4, data + y * rep.bytesPerRow, w * 4) }
        }
        return PixelImage(width: w, height: h, pixels: pixels)
    }

    /// The ideal result: the toolbar, the whole document from `start`, and the input box, each once.
    func fullRender(from start: Int = 0) -> PixelImage {
        let width = Int(container.bounds.width)
        var parts: [PixelImage] = []
        if let header { parts.append(Self.render(header, scale: scale)) }
        let doc = Self.render(document, scale: scale)
        parts.append(doc.rows((start * scale)..<doc.height))
        if let footer { parts.append(Self.render(footer, scale: scale)) }
        let px = parts.flatMap(\.pixels)
        return PixelImage(width: width * scale, height: px.count / (width * scale), pixels: px)
    }
}

func firstDifference(_ a: PixelImage, _ b: PixelImage) -> String? {
    if a.width != b.width || a.height != b.height { return "size \(a.width)×\(a.height) vs \(b.width)×\(b.height)" }
    for y in 0..<a.height where a.row(y) != b.row(y) { return "first difference at row \(y)" }
    return nil
}

@Suite("Offscreen AppKit harness", .serialized)
@MainActor
struct OffscreenHarnessTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var header: CGFloat = 0, footer: CGFloat = 0, scale = 1, start: CGFloat = 0
        var testDescription: String { "header \(Int(header)), footer \(Int(footer)), @\(scale)x, from \(Int(start))" }
    }

    @Test(arguments: [
        Case(),
        Case(header: 44),
        Case(footer: 60),
        Case(header: 44, footer: 60),
        Case(scale: 2),
        Case(header: 38, footer: 52, scale: 2),
        Case(header: 44, start: 913),
    ])
    func captureEqualsFullRender(_ c: Case) async throws {
        let w = OffscreenScrollWindow(rows: 3000, header: c.header, footer: c.footer, scale: c.scale, start: c.start)
        let result = try await CaptureSession(driver: w).run()
        #expect(result.reason == .bottom)
        #expect(firstDifference(result.image, w.fullRender(from: Int(c.start))) == nil)
        let report = BarcodeReport.read(result.image, originX: Double(TestPage.barcodeX * c.scale),
                                        cellWidth: Double(TestPage.cellWidth * c.scale), pixelsPerRow: c.scale)
        #expect(report.isClean)
        #expect(report.first == Int(c.start) && report.last == 2999)
    }
}

@Suite("Offscreen harness: chat overlays and overshoot", .serialized)
@MainActor
struct OffscreenChatTests {
    @Test(arguments: [1, 2])
    func floatingChipsAndFadeOverARealScrollView(scale: Int) async throws {
        let w = OffscreenScrollWindow(rows: 3000, header: 44, footer: 60, scale: scale, chips: 34)
        let r = try await CaptureSession(driver: w).run()
        #expect(r.reason == .bottom)
        #expect(r.footer >= (60 + 34) * scale)
        // Everything above the final overlay band is the document, pixel for pixel: no chip or fade in it.
        let contentEnd = r.image.height - r.footer
        let ideal = w.fullRender()
        #expect(firstDifference(r.image.rows(0..<contentEnd), ideal.rows(0..<contentEnd)) == nil)
        let v = BarcodeCheck.verdict(for: r.image, rows: r.header..<contentEnd)
        #expect(v?.passed == true)
        #expect(v?.report.first == 0)
        // Nothing lost between the content and the band: header, every row and footer, once.
        #expect(r.image.height == ideal.height, "image \(r.image.height) px, expected \(ideal.height)")
    }

    @Test(arguments: [2.5, 3.5])
    func overshootingRealScrollViewIsComplete(factor: Double) async throws {
        let w = OffscreenScrollWindow(rows: 5000, header: 44, footer: 60)
        w.overshoot = CGFloat(factor)
        var o = CaptureOptions()
        o.cautiousStartFraction = 0.3
        o.maxSeconds = 600
        let r = try await CaptureSession(driver: w, options: o).run()
        #expect(r.reason == .bottom)
        #expect(firstDifference(r.image, w.fullRender()) == nil)
        let rep = BarcodeReport.read(r.image, originX: Double(TestPage.barcodeX), cellWidth: Double(TestPage.cellWidth))
        #expect(rep.isClean && rep.first == 0 && rep.last == 4999)
    }
}
