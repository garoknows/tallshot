import AppKit
import ImageIO
import TallshotCore
import UniformTypeIdentifiers

/// Puts a finished capture where the user asked: the clipboard and the save folder, nowhere else.
@MainActor
enum Delivery {
    struct Outcome {
        var file: URL?
        var copied: Bool
        var thumbnail: NSImage?
        var error: String?
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

    /// A name that doesn't overwrite an existing file: "… 2.png", "… 3.png".
    static func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).png")
            n += 1
        }
        return url
    }

    static func pngData(_ cg: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func deliver(_ image: PixelImage, colorSpace: CGColorSpace, scale: CGFloat, settings: Settings, date: Date = Date()) -> Outcome {
        guard let cg = WindowCapturer.cgImage(image, colorSpace: colorSpace), let png = pngData(cg) else {
            return Outcome(file: nil, copied: false, thumbnail: nil, error: "Couldn't make the PNG.")
        }
        var outcome = Outcome(file: nil, copied: false, thumbnail: thumbnail(cg))
        if settings.saveToFolder {
            let url = uniqueURL(in: settings.folderURL, name: fileName(for: date))
            do {
                try png.write(to: url, options: .atomic)   // the finished PNG, in the folder the user chose
                outcome.file = url
            } catch {
                outcome.error = "Couldn't save to \(settings.folderURL.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if settings.copyToClipboard {
            let pb = NSPasteboard.general
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            if let file = outcome.file { item.setString(file.absoluteString, forType: .fileURL) }
            outcome.copied = pb.writeObjects([item])
        }
        return outcome
    }

    /// A small preview of the top of the capture for the toast.
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

    /// "Saved and copied. 8,412 px."
    static func message(_ o: Outcome) -> String {
        switch (o.file != nil, o.copied) {
        case (true, true): "Saved and copied."
        case (true, false): "Saved."
        case (false, true): "Copied."
        case (false, false): "Not saved or copied."
        }
    }

    static func pixels(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return "\(f.string(from: NSNumber(value: n)) ?? "\(n)") px"
    }
}
