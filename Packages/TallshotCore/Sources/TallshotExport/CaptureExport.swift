import CoreGraphics
import Foundation
import TallshotCore

/// Builds every file of a finished capture in memory: the PNG, the PDF, the Word file and the
/// Markdown file, plus what goes on the clipboard. Touches no disk; `ExportFiles.write` saves
/// the result into the folder the user chose. The app decides the plan from its settings.
public enum CaptureExport {
    /// What to make.
    public struct Plan: Sendable {
        public var png: Bool, pdf: Bool, docx: Bool, md: Bool
        public var copyImage: Bool, copyText: Bool
        public var pageSize: PageSize
        public var wordImage: Bool
        /// The files' shared name (without extension). Only the Markdown file's image link uses
        /// it, because that link must point at the PNG saved next to it.
        public var baseName: String

        public init(png: Bool, pdf: Bool, docx: Bool, md: Bool, copyImage: Bool, copyText: Bool,
                    pageSize: PageSize, wordImage: Bool, baseName: String) {
            self.png = png; self.pdf = pdf; self.docx = docx; self.md = md
            self.copyImage = copyImage; self.copyText = copyText
            self.pageSize = pageSize; self.wordImage = wordImage; self.baseName = baseName
        }

        public var needsText: Bool { docx || md || copyText }
        /// The extensions of the files this plan saves, in saving order.
        public var extensions: [String] { [png ? "png" : nil, pdf ? "pdf" : nil, docx ? "docx" : nil, md ? "md" : nil].compactMap { $0 } }
    }

    /// Everything built in memory, before anything is written.
    public struct Built: @unchecked Sendable {
        public var files: [(ext: String, data: Data)] = []
        public var clipboardPNG: Data?
        public var clipboardText: String?
        public var thumbnailSource: CGImage?
        public var textSource: TextSource?
        public var notes: [String] = []
        public var error: String?
    }

    /// Builds the PNG, PDF, Word and Markdown data. Safe to run off the main thread.
    public static func build(_ image: PixelImage, colorSpace: CGColorSpace, accessibilityText: ExportDocument?, plan: Plan) -> Built {
        var out = Built()
        guard let cg = ImageBridge.cgImage(image, colorSpace: colorSpace), let png = ImageBridge.png(cg) else {
            out.error = "Couldn't make the image."
            return out
        }
        out.thumbnailSource = cg
        if plan.png { out.files.append(("png", png)) }
        if plan.copyImage || plan.copyText { out.clipboardPNG = png }

        // The words: the accessibility tree's if it gave any, else text recognized on this Mac.
        var doc = accessibilityText.flatMap { $0.hasText ? $0 : nil }
        var lines: [TextLine] = []
        let needLines = plan.pdf || (plan.needsText && doc == nil)
        if needLines {
            do { lines = try TextRecognition.lines(in: cg, pixels: image) } catch {
                out.notes.append("Text recognition isn't available, so the PDF has no text layer.")
            }
        }
        if plan.needsText && doc == nil, !lines.isEmpty { doc = TextRecognition.document(from: lines) }
        out.textSource = plan.needsText ? doc?.source : nil

        if plan.pdf {
            let pages = PDFExport.pages(for: image, pageSize: plan.pageSize)
            if let pdf = PDFExport.make(image: cg, pages: pages, lines: lines, pageSize: plan.pageSize) {
                out.files.append(("pdf", pdf))
            } else {
                out.notes.append("Couldn't make the PDF.")
            }
        }
        let document = doc ?? ExportDocument(blocks: [], source: .recognized)
        if plan.needsText && !document.hasText { out.notes.append("No text was found for Word or Markdown.") }
        if plan.docx {
            var pictures: [Docx.Picture] = []
            if plan.wordImage {
                for r in PDFExport.pages(for: image, pageSize: .letter) {
                    guard let slice = cg.cropping(to: CGRect(x: 0, y: r.lowerBound, width: cg.width, height: r.count)),
                          let data = ImageBridge.png(slice) else { continue }
                    pictures.append(Docx.Picture(png: data, width: slice.width, height: slice.height))
                }
            }
            out.files.append(("docx", Docx.make(document, pictures: pictures)))
        }
        if plan.md {
            out.files.append(("md", Data(Markdown.render(document, imageFile: plan.png ? plan.baseName + ".png" : nil).utf8)))
        }
        if plan.copyText, document.hasText { out.clipboardText = Markdown.render(document) }
        return out
    }
}
