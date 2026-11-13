import CoreGraphics
import CoreText
import Foundation
import TallshotCore

/// A PDF made from text (a text capture), laid out on Letter or A4 pages with real, searchable
/// text: headings in bold, code and terminal text in a fixed-width font with its spacing kept.
/// Built in memory; nothing is written.
public enum TextPDF {
    public static let margin: CGFloat = 54

    public static func make(_ doc: ExportDocument, pageSize: PageSize) -> Data? {
        let text = attributed(doc)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize.size)
        let info = [kCGPDFContextCreator as String: "Tallshot", kCGPDFContextTitle as String: PDFExport.documentTitle] as CFDictionary
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, info) else { return nil }
        let setter = CTFramesetterCreateWithAttributedString(text)
        let area = CGPath(rect: box.insetBy(dx: margin, dy: margin), transform: nil)
        var start = 0
        let total = text.length
        repeat {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), area, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            let shown = CTFrameGetVisibleStringRange(frame).length
            // Nothing fit (can't happen with these fonts): stop rather than loop forever.
            guard shown > 0 else { break }
            start += shown
        } while start < total
        ctx.closePDF()
        return data as Data
    }

    static func attributed(_ doc: ExportDocument) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let bold = CTFontCreateWithName("Helvetica-Bold" as CFString, 15, nil)
        let mono = CTFontCreateWithName("Menlo-Regular" as CFString, 8.5, nil)
        let speaker = CTFontCreateWithName("Helvetica-Bold" as CFString, 11, nil)
        let font = NSAttributedString.Key(kCTFontAttributeName as String)
        func add(_ s: String, _ f: CTFont) { out.append(NSAttributedString(string: s + "\n", attributes: [font: f])) }
        for block in doc.blocks {
            switch block {
            case .heading(_, let spans): add(spans.map(\.text).joined(), bold)
            case .paragraph(let spans): add(spans.map(\.text).joined(), body)
            case .listItem(let level, _, let spans):
                add(String(repeating: "    ", count: max(0, level)) + "• " + spans.map(\.text).joined(), body)
            case .code(let c, _): add(c, mono)
            case .table(let rows): rows.forEach { add($0.joined(separator: "  |  "), body) }
            case .speaker(let name): add("\n" + name + ":", speaker)
            }
        }
        if out.length == 0 { out.append(NSAttributedString(string: " ", attributes: [font: body])) }
        return out
    }
}

extension CaptureExport.Plan {
    /// The plan for a text capture: no PNG and no image anywhere. The text is saved as Markdown
    /// whenever the settings save anything, and copied (as Markdown) whenever they copy.
    public var forText: CaptureExport.Plan {
        var p = self
        p.md = png || md
        p.png = false
        p.copyText = copyImage || copyText
        p.copyImage = false
        p.wordImage = false
        return p
    }
}

extension CaptureExport {
    /// Builds the Markdown, PDF and Word data for a text capture. Safe to run off the main thread.
    /// Pass `plan.forText`.
    public static func buildText(_ doc: ExportDocument, plan: Plan) -> Built {
        var out = Built()
        out.textSource = doc.source
        if plan.pdf {
            if let pdf = TextPDF.make(doc, pageSize: plan.pageSize) { out.files.append(("pdf", pdf)) } else { out.notes.append("Couldn't make the PDF.") }
        }
        if plan.docx { out.files.append(("docx", Docx.make(doc, pictures: []))) }
        if plan.md { out.files.append(("md", Data(Markdown.render(doc).utf8))) }
        if plan.copyText { out.clipboardText = Markdown.render(doc) }
        return out
    }
}
