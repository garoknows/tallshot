import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import TallshotCore
import TallshotExport

/// This process's memory footprint in bytes (what Activity Monitor's "Memory" column shows).
func memoryFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

/// Decodes PNG data back into 32-bit pixels in the same layout Tallshot uses (BGRA, premultiplied).
func decodePNG(_ data: Data) -> PixelImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    var px = [UInt32](repeating: 0, count: cg.width * cg.height)
    let ok = px.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return true
    }
    return ok ? PixelImage(width: cg.width, height: cg.height, pixels: px) : nil
}

@Suite("November 2026 review fixes: exports", .serialized)
struct ReviewExportTests {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // Finding 5: turning the capture into a CGImage must not copy all its pixels.
    @Test func makingACGImageDoesNotCopyThePixels() throws {
        let side = 5_000   // 25 million pixels: 100 MB
        let image = PixelImage(width: side, height: side, fill: 0xFF33_6699)
        let before = memoryFootprint()
        let cg = try #require(ImageBridge.cgImage(image, colorSpace: srgb))
        let grew = memoryFootprint() - before
        #expect(cg.width == side && cg.height == side)
        #expect(grew < 20_000_000, "making the CGImage added \(grew / 1_000_000) MB")
        withExtendedLifetime(cg) {}
    }

    @Test func theCGImageStillHasExactlyThePixels() throws {
        var image = PixelImage(width: 37, height: 23, fill: 0)
        for y in 0..<23 { for x in 0..<37 { image[x, y] = 0xFF00_0000 | UInt32(x * 6) << 16 | UInt32(y * 10) << 8 | UInt32((x + y) * 3) } }
        let cg = try #require(ImageBridge.cgImage(image, colorSpace: srgb))
        let png = try #require(ImageBridge.png(cg))
        #expect(decodePNG(png) == image)
        // A slice (as the PDF and Word pages use) reads the right rows too.
        let slice = try #require(cg.cropping(to: CGRect(x: 0, y: 10, width: 37, height: 5)))
        #expect(decodePNG(try #require(ImageBridge.png(slice))) == image.rows(10..<15))
    }

    // Finding 6: the descriptive name (page title, domain) may be the files' names, but must not
    // be inside any file, where it would survive a rename.
    static let title = "Secret Page Title 7f3a"
    static let domain = "private-example.com"
    static let baseName = "Google Chrome - \(domain) - \(title) - 2026-11-08 at 14.05 - Tallshot"

    func builtFiles() throws -> [String: Data] {
        var image = PixelImage(width: 300, height: 900, fill: 0xFFFF_FFFF)
        for y in stride(from: 40, to: 860, by: 40) { for x in 30..<270 { for d in 0..<10 { image[x, y + d] = 0xFF20_2020 } } }
        let plan = CaptureExport.Plan(png: true, pdf: true, docx: true, md: true, copyImage: false, copyText: false,
                                      pageSize: .letter, wordImage: true, baseName: Self.baseName)
        let doc = ExportDocument(blocks: [.heading(level: 1, [Inline("Hello")]), .paragraph([Inline("Some words.")])], source: .accessibility)
        let built = CaptureExport.build(image, colorSpace: srgb, accessibilityText: doc, plan: plan)
        #expect(built.error == nil)
        return Dictionary(uniqueKeysWithValues: built.files.map { ($0.ext, $0.data) })
    }

    /// The pieces of the descriptive name that must never be inside a file, plus who's logged in.
    var forbidden: [String] {
        [Self.title, Self.domain, Self.baseName, NSUserName(), NSFullUserName()].filter { !$0.isEmpty }
    }

    func contains(_ data: Data, _ text: String) -> Bool {
        let utf16 = text.data(using: .utf16BigEndian) ?? Data()
        return data.range(of: Data(text.utf8)) != nil || (!utf16.isEmpty && data.range(of: utf16) != nil)
    }

    @Test func thePDFsInformationHasNoTitleOrName() throws {
        let pdfData = try #require(try builtFiles()["pdf"])
        let pdf = try #require(PDFDocument(data: pdfData))
        let attributes = pdf.documentAttributes ?? [:]
        #expect(attributes[PDFDocumentAttribute.titleAttribute] as? String == "Tallshot capture")
        for (key, value) in attributes {
            let text = "\(value)"
            for bad in forbidden { #expect(!text.contains(bad), "PDF \(key) holds \(bad)") }
        }
        for bad in forbidden { #expect(!contains(pdfData, bad), "PDF bytes hold \(bad)") }
    }

    @Test func theWordFileHasNoTitleOrName() throws {
        let docx = try #require(try builtFiles()["docx"])
        let entries = Zip.entries(docx)
        #expect(!entries.isEmpty)
        for (name, data) in entries {
            for bad in forbidden { #expect(!contains(data, bad), "\(name) holds \(bad)") }
        }
    }

    @Test func thePNGHasNoTextChunks() throws {
        let png = try #require(try builtFiles()["png"])
        var types: [String] = []
        var i = 8
        while i + 8 <= png.count {
            let length = png[i..<(i + 4)].reduce(0) { $0 << 8 | Int($1) }
            types.append(String(decoding: png[(i + 4)..<(i + 8)], as: UTF8.self))
            i += 12 + length
        }
        #expect(types.first == "IHDR" && types.last == "IEND")
        // ImageIO adds an eXIf chunk with only the color space and the size; text chunks are banned.
        #expect(types.allSatisfy { !["tEXt", "zTXt", "iTXt"].contains($0) }, "chunks: \(types)")
        for bad in forbidden { #expect(!contains(png, bad), "PNG holds \(bad)") }
    }

    @Test func markdownOnlyLinksTheImageFileWithPlainAltText() throws {
        let md = String(decoding: try #require(try builtFiles()["md"]), as: UTF8.self)
        #expect(md.hasPrefix("![Tallshot capture](<\(Self.baseName).png>)"))
        // Apart from the link to the PNG beside it, the name appears nowhere.
        let rest = md.replacingOccurrences(of: "(<\(Self.baseName).png>)", with: "")
        for bad in forbidden { #expect(!rest.contains(bad), "Markdown holds \(bad)") }
    }
}
