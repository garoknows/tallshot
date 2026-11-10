import CoreGraphics
import CoreText
import Foundation
import TallshotCore

public enum PageSize: String, CaseIterable, Sendable {
    case letter, a4
    public var title: String { self == .letter ? "Letter" : "A4" }
    /// In PDF points (1/72 inch).
    public var size: CGSize { self == .letter ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89) }
}

/// Builds a PDF in memory: the tall capture split into pages (cut between lines of text where
/// possible), with an invisible, selectable text layer so the PDF can be searched.
public enum PDFExport {
    public static let margin: CGFloat = 36

    /// Pixels of the capture that fit on one page.
    public static func pagePixelHeight(imageWidth: Int, pageSize: PageSize) -> Int {
        let s = pageSize.size
        let scale = (s.width - 2 * margin) / CGFloat(imageWidth)   // points per pixel
        return max(1, Int(((s.height - 2 * margin) / scale).rounded(.down)))
    }

    /// The page ranges (in image rows) for `image`.
    public static func pages(for image: PixelImage, pageSize: PageSize) -> [Range<Int>] {
        let blank = PageBreaker.blankRows(image)
        return PageBreaker.pages(height: image.height, pageHeight: pagePixelHeight(imageWidth: image.width, pageSize: pageSize)) { blank[$0] }
    }

    /// The PDF's title. Always this, never the capture's name: the name can hold a page title or a
    /// web address, and inside the file it would stay after the file is renamed.
    public static let documentTitle = "Tallshot capture"

    /// The PDF. `lines` are text lines in image pixels (from text recognition), drawn invisibly.
    public static func make(image: CGImage, pages: [Range<Int>], lines: [TextLine], pageSize: PageSize) -> Data? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize.size)
        let info = [kCGPDFContextCreator as String: "Tallshot", kCGPDFContextTitle as String: documentTitle] as CFDictionary
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, info) else { return nil }
        let scale = (box.width - 2 * margin) / CGFloat(image.width)
        for range in pages {
            ctx.beginPDFPage(nil)
            let top = box.height - margin
            let sliceH = CGFloat(range.count) * scale
            if let slice = image.cropping(to: CGRect(x: 0, y: range.lowerBound, width: image.width, height: range.count)) {
                ctx.interpolationQuality = .high
                ctx.draw(slice, in: CGRect(x: margin, y: top - sliceH, width: box.width - 2 * margin, height: sliceH))
            }
            // The invisible text layer: each line where it appears on the page, stretched to its width.
            ctx.setTextDrawingMode(.invisible)
            for l in lines where Double(range.lowerBound) <= l.y + l.height / 2 && l.y + l.height / 2 < Double(range.upperBound) {
                let h = CGFloat(l.height) * scale, w = CGFloat(l.width) * scale
                guard h > 0.5, w > 0.5 else { continue }
                let font = CTFontCreateWithName("Helvetica" as CFString, h * 0.85, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: l.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                let natural = CTLineGetTypographicBounds(line, nil, nil, nil)
                let sx = natural > 0 ? w / CGFloat(natural) : 1
                let baseline = top - (CGFloat(l.y - Double(range.lowerBound)) * scale) - h * 0.8
                ctx.saveGState()
                ctx.concatenate(CGAffineTransform(scaleX: sx, y: 1))
                ctx.textMatrix = .identity
                ctx.textPosition = CGPoint(x: (margin + CGFloat(l.x) * scale) / sx, y: baseline)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
}
