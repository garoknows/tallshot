import AppKit
import TallshotCore
import TallshotExport

/// Puts a finished capture where the user asked: the clipboard and the save folder, nowhere else.
/// Every format is built in memory first (off the main thread, by `CaptureExport`), then written
/// together into the chosen folder under one base name (see `CaptureName`), with ".png", ".pdf",
/// ".docx", ".md".
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

    struct Input: @unchecked Sendable {
        var image: PixelImage
        var colorSpace: CGColorSpace
        var accessibilityText: ExportDocument?
    }

    static func deliver(_ image: PixelImage, colorSpace: CGColorSpace, settings: Settings, accessibilityText: ExportDocument?,
                        baseName: String) async -> Outcome {
        let folder = settings.folderURL
        var plan = CaptureExport.Plan(settings: settings, baseName: baseName)
        plan.baseName = ExportFiles.uniqueBaseName(plan.baseName, extensions: plan.extensions, folder: folder, ending: CaptureName.ending)
        let input = Input(image: image, colorSpace: colorSpace, accessibilityText: accessibilityText)
        let p = plan
        let built = await Task.detached(priority: .userInitiated) {
            CaptureExport.build(input.image, colorSpace: input.colorSpace, accessibilityText: input.accessibilityText, plan: p)
        }.value

        var outcome = Outcome(thumbnail: built.thumbnailSource.flatMap(thumbnail), error: built.error,
                              textSource: built.textSource, notes: built.notes)
        if !built.files.isEmpty {
            let written = ExportFiles.write(built.files, baseName: plan.baseName, folder: folder)
            outcome.files = written.files
            if let error = written.error {
                let kept = written.files.isEmpty ? "" : " Only some files were saved."
                outcome.error = "Couldn't save to \(folder.lastPathComponent): \(error.localizedDescription)\(kept)"
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

    /// A small preview of the top of the capture for the pop-up.
    static func thumbnail(_ cg: CGImage) -> NSImage? {
        guard cg.width > 0, cg.height > 0 else { return nil }
        let h = min(cg.height, Int(Double(cg.width) * 128 / 88))
        guard let top = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: h)) else { return nil }
        // Keep the shape: a short capture gets a short thumbnail, not a stretched one.
        let drawn = max(1, (88 * CGFloat(h) / CGFloat(cg.width)).rounded())
        let out = NSImage(size: NSSize(width: 88, height: 128))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: top, size: .zero).draw(in: NSRect(x: 0, y: 128 - drawn, width: 88, height: drawn))
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

extension CaptureExport.Plan {
    /// What to make, decided on the main thread from the settings.
    @MainActor init(settings: Settings, baseName: String) {
        self.init(png: settings.saveToFolder, pdf: settings.savePDF, docx: settings.saveDOCX, md: settings.saveMarkdown,
                  copyImage: settings.copyToClipboard && settings.copyAs == .image,
                  copyText: settings.copyToClipboard && settings.copyAs == .text,
                  pageSize: settings.pdfPageSize, wordImage: settings.wordIncludesImage, baseName: baseName)
    }
}
