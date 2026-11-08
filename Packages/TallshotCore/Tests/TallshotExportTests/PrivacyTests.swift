import CoreGraphics
import Foundation
import Testing
import TallshotCore
import TallshotExport

/// A window over a tall generated page: the capture loop scrolls it and takes its pictures.
@MainActor
final class PageWindow: CaptureDriver {
    let page: PixelImage
    let height: Int
    var pos = 0
    private var clock = 0.0
    init(page: PixelImage, height: Int) { self.page = page; self.height = height }
    func captureFrame() async throws -> PixelImage { clock += 0.01; return page.rows(pos..<(pos + height)) }
    func scroll(pixels: Int) async throws { pos = min(max(0, pos + pixels), page.height - height); clock += 0.01 }
    func pause(milliseconds: Int) async { clock += Double(milliseconds) / 1000 }
    var isCancelled: Bool { false }
    var now: Double { clock }
}

/// A capture goes only into the folder the user chose. These tests run the same code the app
/// runs after a capture (`CaptureExport.build`, `ExportFiles.write`, `DiagnosticsReport.write`),
/// with diagnostics on and off, then look inside every file changed anywhere the app or the
/// system could have put a copy: the chosen folder must hold the content (proving the search can
/// see it), and nothing else may.
@Suite("Private: content stays in the chosen folder", .serialized)
@MainActor
struct PrivacyTests {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Where a stray copy could land: temp folders, caches, Application Support, preferences,
    /// containers and saved window state, searched all the way down. The Desktop (the default save
    /// folder) is searched at its top level, `desktop`, since people keep whole projects in it.
    nonisolated static var placesToSearch: [URL] {
        let fm = FileManager.default
        let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return [fm.temporaryDirectory, URL(fileURLWithPath: NSTemporaryDirectory()),
                fm.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                lib.appendingPathComponent("Preferences"), lib.appendingPathComponent("Containers"),
                lib.appendingPathComponent("Saved Application State")]
    }
    nonisolated static var desktop: URL { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0] }

    /// Where the tests make their folders (the caches, which some sandboxes allow and temp doesn't).
    static var workFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Tallshot-build/privacy-tests")
    }

    struct Saved { var folder: URL; var files: [String: URL]; var report: URL?; var scanner: DiskScanner }

    /// One capture, saved in every format into a new folder. With `diagnostics`, it stops early
    /// (at a low height limit) and keeps a diagnostic report next to the files.
    func captureAndSave(diagnostics: Bool) async throws -> Saved {
        let marker = "Tallshot privacy marker \(UInt64.random(in: 1...UInt64.max))"
        let page = TestPage.make(width: 320, height: 2_400, seed: UInt64.random(in: 1...UInt64.max))
        var options = CaptureOptions()
        options.keepDiagnostics = diagnostics
        if diagnostics { options.maxHeight = 1_200 }
        let result = try await CaptureSession(driver: PageWindow(page: page, height: 360), options: options).run()
        #expect(result.reason == (diagnostics ? .heightCap : .bottom))
        #expect((result.diagnostics != nil) == diagnostics, "frames are kept only with diagnostics on")

        let folder = Self.workFolder.appendingPathComponent("chosen \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "Privacy App - \(marker) - 2026-11-08 at 10.00 - Tallshot"
        let plan = CaptureExport.Plan(png: true, pdf: true, docx: true, md: true, copyImage: true, copyText: false,
                                      pageSize: .letter, wordImage: true, baseName: name)
        let doc = ExportDocument(blocks: [.heading(level: 1, [Inline("Notes")]), .paragraph([Inline(marker)])], source: .accessibility)
        let built = CaptureExport.build(result.image, colorSpace: Self.srgb, accessibilityText: doc, plan: plan)
        #expect(built.error == nil)
        let written = ExportFiles.write(built.files, baseName: name, folder: folder)
        #expect(written.error == nil)
        // The app writes a report only when the setting is on and the capture stopped early
        // (DiagnosticsWriter.shouldWrite); with it off there are no frames to write.
        let report = DiagnosticsReport.write(result, region: "0, 0, 160 x 180 points, scrollArea", appName: "App \(marker)",
                                             colorSpace: Self.srgb, folder: folder, baseName: name)
        #expect((report != nil) == diagnostics)
        // Pixel rows that only this capture has (inside its first frame, so a report frame has them too).
        let rows = [60, 200, 330].map { Array(result.image.row($0)) }
        return Saved(folder: folder, files: written.files, report: report, scanner: DiskScanner(texts: [marker], rows: rows))
    }

    /// The search can see the content where it was meant to go, in each format.
    func checkTheFolderHoldsIt(_ saved: Saved, diagnostics: Bool) throws {
        let s = saved.scanner
        func found(_ ext: String) -> Set<String> { saved.files[ext].flatMap { try? Data(contentsOf: $0) }.map { s.findings(in: $0) } ?? [] }
        #expect(found("png").contains("pixels"), "the search can't see pixels in a PNG")
        #expect(found("pdf").contains("pixels"), "the search can't see pixels in a PDF")
        #expect(found("docx").isSuperset(of: ["text", "pixels"]), "the search can't see text and pixels in a Word file")
        #expect(found("md").contains("text"), "the search can't see text in Markdown")
        if let report = saved.report {
            let frames = try FileManager.default.contentsOfDirectory(at: report, includingPropertiesForKeys: nil)
            #expect(frames.contains { $0.pathExtension == "png" && s.findings(in: (try? Data(contentsOf: $0)) ?? Data()).contains("pixels") })
            #expect(s.findings(in: try Data(contentsOf: report.appendingPathComponent("report.txt"))).contains("text"))
        } else {
            // With diagnostics off, the chosen folder holds exactly the four files.
            let names = try FileManager.default.contentsOfDirectory(atPath: saved.folder.path)
            #expect(Set(names.map { ($0 as NSString).pathExtension }) == ["png", "pdf", "docx", "md"] && names.count == 4)
        }
    }

    /// Two captures (diagnostics off, then on) saved the way the app saves them, plus a planted
    /// stray copy of the first one's files. One search of every place a copy could land must find
    /// the planted copies (or the search proves nothing) and nothing else.
    @Test func captureContentStaysInTheChosenFolder() async throws {
        let started = Date().addingTimeInterval(-2)
        let off = try await captureAndSave(diagnostics: false)
        let on = try await captureAndSave(diagnostics: true)
        let stray = Self.workFolder.appendingPathComponent("stray \(UUID().uuidString)")
        defer { for f in [off.folder, on.folder, stray] { try? FileManager.default.removeItem(at: f) } }
        try checkTheFolderHoldsIt(off, diagnostics: false)
        try checkTheFolderHoldsIt(on, diagnostics: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        for (ext, url) in off.files { try FileManager.default.copyItem(at: url, to: stray.appendingPathComponent("copy.\(ext)")) }

        let both = DiskScanner(texts: off.scanner.texts + on.scanner.texts, rows: off.scanner.rows + on.scanner.rows)
        let hits = both.scan(Self.placesToSearch, topLevelOnly: [Self.desktop], changedSince: started, skipping: [off.folder, on.folder])
        let strayPath = stray.resolvingSymlinksInPath().path
        for ext in ["png", "pdf", "docx", "md"] {
            #expect(hits.keys.contains("\(strayPath)/copy.\(ext)"), "the search missed a stray .\(ext), so it can't be trusted")
        }
        for (path, what) in hits where !path.hasPrefix(strayPath + "/") {
            Issue.record("capture \(what.sorted().joined(separator: " and ")) found outside the chosen folder: \(path)")
        }
    }
}
