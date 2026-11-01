import AppKit
import TallshotCore
import TallshotExport

/// Puts a finished capture where the user asked: the clipboard and the save folder, nowhere else.
/// Every format is built in memory first (off the main thread), then written together into the
/// chosen folder under one base name: "Tallshot 2026-10-31 at 14.05.22.png", ".pdf", ".docx", ".md".
@MainActor
enum Delivery {
    struct Outcome {
        /// Files written, by extension ("png", "pdf", "docx", "md").
        var files: [String: URL] = [:]
        var copied = false
        var copiedText = false
        var thumbnail: NSImage?
        var error: String?
        var textSource: TextSource?
        var notes: [String] = []

        /// The file a click on the pop-up opens: the PNG, else the first export.
        var file: URL? { files["png"] ?? files["pdf"] ?? files["docx"] ?? files["md"] }
    }

    /// What to make, decided on the main thread from the settings.
    struct Plan: Sendable {
        var png: Bool, pdf: Bool, docx: Bool, md: Bool
        var copyImage: Bool, copyText: Bool
        var pageSize: PageSize
        var wordImage: Bool
        var baseName: String

        @MainActor init(settings: Settings, baseName: String) {
            png = settings.saveToFolder; pdf = settings.savePDF; docx = settings.saveDOCX; md = settings.saveMarkdown
            copyImage = settings.copyToClipboard && settings.copyAs == .image
            copyText = settings.copyToClipboard && settings.copyAs == .text
            pageSize = settings.pdfPageSize; wordImage = settings.wordIncludesImage
            self.baseName = baseName
        }

        var needsText: Bool { docx || md || copyText }
    }

    /// Everything built in memory, before anything is written.
    struct Built: @unchecked Sendable {
        var files: [(ext: String, data: Data)] = []
        var clipboardPNG: Data?
        var clipboardText: String?
        var thumbnailSource: CGImage?
        var textSource: TextSource?
        var notes: [String] = []
        var error: String?
    }

    struct Input: @unchecked Sendable {
        var image: PixelImage
        var colorSpace: CGColorSpace
        var accessibilityText: ExportDocument?
    }

    /// "Tallshot 2026-10-31 at 14.05.22"
    static func baseName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Tallshot \(f.string(from: date))"
    }

    /// "Tallshot 2026-10-31 at 14.05.22.png"
    static func fileName(for date: Date) -> String { baseName(for: date) + ".png" }

    static func pngData(_ cg: CGImage) -> Data? { ImageBridge.png(cg) }

    static func deliver(_ image: PixelImage, colorSpace: CGColorSpace, settings: Settings, accessibilityText: ExportDocument?,
                        date: Date = Date()) async -> Outcome {
        let folder = settings.folderURL
        var plan = Plan(settings: settings, baseName: baseName(for: date))
        let exts = [plan.png ? "png" : nil, plan.pdf ? "pdf" : nil, plan.docx ? "docx" : nil, plan.md ? "md" : nil].compactMap { $0 }
        plan.baseName = ExportFiles.uniqueBaseName(plan.baseName, extensions: exts, folder: folder)
        let input = Input(image: image, colorSpace: colorSpace, accessibilityText: accessibilityText)
        let p = plan
        let built = await Task.detached(priority: .userInitiated) { build(input, p) }.value

        var outcome = Outcome(thumbnail: built.thumbnailSource.flatMap(thumbnail), error: built.error,
                              textSource: built.textSource, notes: built.notes)
        if !built.files.isEmpty {
            do {
                outcome.files = try ExportFiles.write(built.files, baseName: plan.baseName, folder: folder)
            } catch {
                outcome.error = "Couldn't save to \(folder.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if plan.copyText, let text = built.clipboardText {
            let pb = NSPasteboard.general
            pb.clearContents()
            outcome.copied = pb.setString(text, forType: .string)
            outcome.copiedText = outcome.copied
        } else if plan.copyImage || plan.copyText, let png = built.clipboardPNG {
            // Copy as Text with no words found falls back to the image, and says so.
            if plan.copyText { outcome.notes.append("No text found to copy, so the image was copied.") }
            let pb = NSPasteboard.general
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            if let file = outcome.files["png"] { item.setString(file.absoluteString, forType: .fileURL) }
            outcome.copied = pb.writeObjects([item])
        }
        return outcome
    }

    /// Builds the PNG, PDF, Word and Markdown data. Runs off the main thread; touches no disk.
    nonisolated static func build(_ input: Input, _ plan: Plan) -> Built {
        var out = Built()
        guard let cg = ImageBridge.cgImage(input.image, colorSpace: input.colorSpace), let png = ImageBridge.png(cg) else {
            out.error = "Couldn't make the image."
            return out
        }
        out.thumbnailSource = cg
        if plan.png { out.files.append(("png", png)) }
        if plan.copyImage || plan.copyText { out.clipboardPNG = png }

        // The words: the accessibility tree's if it gave any, else text recognized on this Mac.
        var doc = input.accessibilityText.flatMap { $0.hasText ? $0 : nil }
        var lines: [TextLine] = []
        let needLines = plan.pdf || (plan.needsText && doc == nil)
        if needLines {
            do { lines = try TextRecognition.lines(in: cg, pixels: input.image) } catch {
                out.notes.append("Text recognition isn't available, so the PDF has no text layer.")
            }
        }
        if plan.needsText && doc == nil, !lines.isEmpty { doc = TextRecognition.document(from: lines) }
        out.textSource = plan.needsText ? doc?.source : nil

        if plan.pdf {
            let pages = PDFExport.pages(for: input.image, pageSize: plan.pageSize)
            if let pdf = PDFExport.make(image: cg, pages: pages, lines: lines, pageSize: plan.pageSize, title: plan.baseName) {
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
                for r in PDFExport.pages(for: input.image, pageSize: .letter) {
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

    /// A small preview of the top of the capture for the pop-up.
    static func thumbnail(_ cg: CGImage) -> NSImage? {
        let w = 88, h = min(cg.height, Int(Double(cg.width) * 128 / 88))
        guard let top = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: h)) else { return nil }
        let out = NSImage(size: NSSize(width: w, height: 128))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: top, size: .zero).draw(in: NSRect(x: 0, y: 0, width: w, height: 128))
        out.unlockFocus()
        return out
    }

    /// "Saved and copied." / "Saved PNG and PDF, copied as text."
    static func message(_ o: Outcome) -> String {
        let saved = !o.files.isEmpty
        let copied = o.copiedText ? "copied as text" : "copied"
        switch (saved, o.copied) {
        case (true, true): return "Saved and \(copied)."
        case (true, false): return "Saved."
        case (false, true): return o.copiedText ? "Copied as text." : "Copied."
        case (false, false): return "Not saved or copied."
        }
    }

    /// "Also saved PDF, Word and Markdown." (nil when only the PNG was saved)
    static func exportsLine(_ o: Outcome) -> String? {
        let names = [("pdf", "PDF"), ("docx", "Word"), ("md", "Markdown")].filter { o.files[$0.0] != nil }.map(\.1)
        guard !names.isEmpty else { return nil }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return (o.files["png"] != nil ? "Also saved " : "Saved ") + list + "."
    }

    static func pixels(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return "\(f.string(from: NSNumber(value: n)) ?? "\(n)") px"
    }
}
