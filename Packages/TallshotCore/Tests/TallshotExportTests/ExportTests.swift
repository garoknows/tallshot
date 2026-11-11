import AppKit
import Foundation
import PDFKit
import Testing
import TallshotCore
import TallshotExport

/// Vision can't run inside some restricted sandboxes; on CI it must.
let visionCanRun = TextRecognition.isAvailable || ProcessInfo.processInfo.environment["CI"] != nil

/// A generated page: a heading, a paragraph, nested bullets and a code block, as structure.
let samplePage: [Block] = [
    .heading(level: 1, [Inline("Project kickoff notes")]),
    .paragraph([Inline("The team agreed on three goals for the first month and a weekly review.")]),
    .heading(level: 2, [Inline("Goals")]),
    .listItem(level: 0, ordered: false, [Inline("Ship the export feature")]),
    .listItem(level: 1, ordered: false, [Inline("Searchable PDF pages")]),
    .listItem(level: 1, ordered: false, [Inline("Word and Markdown files")]),
    .listItem(level: 0, ordered: false, [Inline("Write the documentation")]),
    .heading(level: 2, [Inline("Example")]),
    .code("let pages = 3\nprint(pages)"),
    .paragraph([Inline("Read the "), Inline("full plan", link: "https://example.com/plan"), Inline(" before Friday.")]),
]

/// Renders a page as pixels, the way a capture would look: text drawn by Core Text.
func renderPage(_ blocks: [Block], width: Int = 1100) -> (CGImage, PixelImage) {
    var items: [(String, NSFont, CGFloat, Bool)] = []   // text, font, x, shaded
    for b in blocks {
        switch b {
        case .heading(let l, let s): items.append((s.map(\.text).joined(), .boldSystemFont(ofSize: l == 1 ? 40 : 30), 40, false))
        case .paragraph(let s): items.append((s.map(\.text).joined(), .systemFont(ofSize: 20), 40, false))
        case .listItem(let l, let o, let s): items.append(((o ? "1. " : (l == 0 ? "• " : "◦ ")) + s.map(\.text).joined(), .systemFont(ofSize: 20), 60 + CGFloat(l) * 44, false))
        case .table(let rows): for r in rows { items.append((r.joined(separator: " | "), .systemFont(ofSize: 20), 40, false)) }
        case .code(let c, _): for line in c.split(separator: "\n") { items.append((String(line), .monospacedSystemFont(ofSize: 19, weight: .regular), 70, true)) }
        case .speaker(let name): items.append((name + ":", .boldSystemFont(ofSize: 20), 40, false))
        }
    }
    let height = 60 + items.count * 62
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
    ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
    var y: CGFloat = 30
    for (text, font, x, shaded) in items {
        let size = (text as NSString).size(withAttributes: [.font: font])
        if shaded { NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 50, y: y - 6, width: CGFloat(width) - 100, height: size.height + 12).fill() }
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: NSColor.black])
        y += max(44, size.height + (font.pointSize > 25 ? 24 : 20))
    }
    NSGraphicsContext.restoreGraphicsState()
    let cg = ctx.makeImage()!
    var px = [UInt32](repeating: 0, count: width * height)
    memcpy(&px, ctx.data!, width * height * 4)
    return (cg, PixelImage(width: width, height: height, pixels: px))
}

func docxXML(_ data: Data) -> String { String(decoding: Zip.entries(data)["word/document.xml"] ?? Data(), as: UTF8.self) }

@Suite("Exports: text from the accessibility tree", .serialized)
struct AccessibilityPathTests {
    /// The page scrolled past in overlapping steps, as the accessibility snapshots arrive.
    func merged(_ blocks: [Block], window: Int, step: Int) -> ExportDocument {
        var m = SnapshotMerger()
        var top = 0
        while top < blocks.count { m.add(Array(blocks[top..<min(blocks.count, top + window)])); top += step }
        return ExportDocument(blocks: m.blocks, source: .accessibility)
    }

    @Test func markdownStructure() {
        let doc = merged(samplePage, window: 4, step: 3)
        #expect(doc.blocks == samplePage)
        let md = Markdown.render(doc, imageFile: "Tallshot 2026-10-31 at 14.05.22.png")
        #expect(md.contains("# Project kickoff notes\n"))
        #expect(md.contains("## Goals\n\n- Ship the export feature\n  - Searchable PDF pages\n  - Word and Markdown files\n- Write the documentation\n"))
        #expect(md.contains("```\nlet pages = 3\nprint(pages)\n```"))
        #expect(md.contains("[full plan](https://example.com/plan)"))
        #expect(md.contains("accessibility tree"))
    }

    @Test func wordStructure() throws {
        let doc = merged(samplePage, window: 4, step: 3)
        let data = Docx.make(doc)
        let files = Zip.entries(data)
        for name in ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/numbering.xml", "word/_rels/document.xml.rels"] {
            #expect(files[name] != nil, "missing \(name)")
        }
        let xml = docxXML(data)
        #expect(xml.contains("<w:pStyle w:val=\"Heading1\"/></w:pPr><w:r><w:t xml:space=\"preserve\">Project kickoff notes</w:t>"))
        #expect(xml.components(separatedBy: "<w:pStyle w:val=\"Heading2\"/>").count == 3)
        #expect(xml.contains("<w:ilvl w:val=\"1\"/><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t xml:space=\"preserve\">Searchable PDF pages"))
        #expect(xml.contains("<w:pStyle w:val=\"Code\"/></w:pPr><w:r><w:t xml:space=\"preserve\">let pages = 3</w:t></w:r><w:r><w:br/></w:r>"))
        #expect(xml.contains("<w:hyperlink r:id=\"rIdLink1\">"))
        let rels = String(decoding: files["word/_rels/document.xml.rels"]!, as: UTF8.self)
        #expect(rels.contains("Target=\"https://example.com/plan\" TargetMode=\"External\""))
        #expect(xml.contains("accessibility tree"))
        // macOS's own Word reader opens it and finds the words in order.
        let back = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        let words = back.string
        var last = words.startIndex
        for b in samplePage {
            let first = b.plainText.split(separator: "\n").first.map(String.init) ?? ""
            guard let r = words.range(of: first, range: last..<words.endIndex) else { Issue.record("missing \(first)"); continue }
            last = r.upperBound
        }
    }

    @Test func wordCanIncludeTheImageAsPages() throws {
        let (cg, px) = renderPage(samplePage)
        let pages = PDFExport.pages(for: px, pageSize: .letter)
        let pictures = pages.compactMap { r -> Docx.Picture? in
            guard let slice = cg.cropping(to: CGRect(x: 0, y: r.lowerBound, width: cg.width, height: r.count)), let png = ImageBridge.png(slice) else { return nil }
            return Docx.Picture(png: png, width: slice.width, height: slice.height)
        }
        let data = Docx.make(ExportDocument(blocks: samplePage, source: .accessibility), pictures: pictures)
        let files = Zip.entries(data)
        #expect(files["word/media/image1.png"] != nil)
        #expect(docxXML(data).contains("r:embed=\"rIdImage1\""))
        _ = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
    }

    @Test func zipRoundTrip() {
        let entries = [(name: "a.txt", data: Data("hello".utf8)), (name: "dir/b.bin", data: Data((0..<300).map { UInt8($0 % 256) }))]
        let back = Zip.entries(Zip.archive(entries))
        #expect(back["a.txt"] == entries[0].data && back["dir/b.bin"] == entries[1].data)
        #expect(Zip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}

@Suite("Exports: recognized text", .serialized, .enabled(if: visionCanRun))
struct RecognizedPathTests {
    @Test func markdownAndWordFromThePixels() throws {
        let (cg, px) = renderPage(samplePage)
        let lines = try TextRecognition.lines(in: cg, pixels: px)
        let doc = TextRecognition.document(from: lines)
        #expect(doc.source == .recognized)
        let md = Markdown.render(doc)
        #expect(md.contains("# Project kickoff notes"))
        #expect(md.contains("## Goals"))
        #expect(md.contains("- Ship the export feature"))
        #expect(md.contains("  - Searchable PDF pages"))
        #expect(md.contains("```\n"))
        #expect(md.contains("recognized from the image"))
        let xml = docxXML(Docx.make(doc))
        #expect(xml.contains("Heading1") && xml.contains("<w:ilvl w:val=\"1\"/>") && xml.contains("w:val=\"Code\""))
    }

    @Test func tallImageIsReadInTilesWithNothingTwice() throws {
        var blocks: [Block] = []
        for i in 0..<120 { blocks.append(.paragraph([Inline("Line number \(i) of the long page")])) }
        let (cg, px) = renderPage(blocks, width: 900)
        let lines = try TextRecognition.lines(in: cg, pixels: px)
        let numbers = lines.compactMap { l in l.text.split(separator: " ").dropFirst(2).first.flatMap { Int($0) } }
        #expect(numbers.count >= 110)
        #expect(Set(numbers).count == numbers.count)          // none read twice
        #expect(numbers == numbers.sorted())                   // in order
    }
}

@Suite("Exports: PDF", .serialized)
struct PDFTests {
    @Test func pagesBreaksAndSearchableText() throws {
        var blocks: [Block] = []
        for i in 0..<160 { blocks.append(.paragraph([Inline("Paragraph \(i) about the quarterly plan")])) }
        let (cg, px) = renderPage(blocks, width: 1000)
        let pages = PDFExport.pages(for: px, pageSize: .letter)
        let perPage = PDFExport.pagePixelHeight(imageWidth: 1000, pageSize: .letter)
        let minimum = Int((Double(px.height) / Double(perPage)).rounded(.up))
        #expect(pages.count >= minimum && pages.count <= Int((Double(px.height) / (Double(perPage) * 0.85)).rounded(.up)))
        let blank = PageBreaker.blankRows(px)
        for p in pages.dropLast() { #expect(blank[p.upperBound - 1] && blank[p.upperBound], "cut through text at row \(p.upperBound)") }
        // The text layer, from known line positions (independent of Vision).
        let lines = (0..<160).map { i in TextLine(text: "Paragraph \(i) about the quarterly plan", x: 40, y: 30 + Double(i) * 62, width: 400, height: 24) }
        let data = try #require(PDFExport.make(image: cg, pages: pages, lines: lines, pageSize: .letter))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == pages.count)
        let text = pdf.string ?? ""
        #expect(text.contains("Paragraph 0 about the quarterly plan"))
        #expect(text.contains("Paragraph 159 about the quarterly plan"))
        #expect(!pdf.findString("quarterly plan", withOptions: []).isEmpty)
        // A4 is narrower and taller: a different number of pages.
        #expect(PDFExport.pagePixelHeight(imageWidth: 1000, pageSize: .a4) > perPage)
    }
}

@Suite("Exports: the browser chat test page", .serialized)
struct ChatPageExportTests {
    /// The same made-up conversation as site/test/chat/index.html (same generator).
    static func messages(total: Int = 60) -> [(user: Bool, height: Int, who: String, paras: [String])] {
        let words = ("the a plan step list idea check note result first next then also because simple quick small "
            + "page column window scroll line box chip test value number order example answer question part shows "
            + "keeps moves stays clear short long left right top bottom middle again careful better").split(separator: " ").map(String.init)
        return (0..<total).map { i in
            var s = UInt32(truncatingIfNeeded: i * 7919 + 13)
            func r() -> Double { s = s &* 1_664_525 &+ 1_013_904_223; return Double(s) / 4_294_967_296 }
            let user = i % 2 == 0
            let height = user ? 70 + Int(r() * 50) : 150 + Int(r() * 190)
            let nP = user ? 1 : 1 + Int(r() * 3)
            var paras: [String] = []
            for _ in 0..<nP {
                let n = 10 + Int(r() * 30)
                var w = (0..<n).map { _ in words[Int(r() * Double(words.count))] }
                w[0] = w[0].prefix(1).uppercased() + w[0].dropFirst()
                paras.append(w.joined(separator: " ") + ".")
            }
            return (user, height, "\(user ? "You" : "Assistant") · message \(i + 1)", paras)
        }
    }

    @Test func everyMessageOnceInOrder() {
        let msgs = Self.messages()
        // Lay the chat out, then scroll a 700 px window down it in 560 px steps (80%), taking an
        // accessibility snapshot of what's visible at each step.
        var y = 0, items: [(top: Int, bottom: Int, block: Block)] = []
        for m in msgs {
            items.append((y, y + 30, .paragraph([Inline(m.who)])))
            for (k, p) in m.paras.enumerated() { items.append((y + 30 + k * 40, y + 70 + k * 40, .paragraph([Inline(p)]))) }
            y += m.height
        }
        var merger = SnapshotMerger()
        var top = 0
        while top < y { merger.add(items.filter { $0.bottom > top && $0.top < top + 700 }.map(\.block)); top += 560 }
        let md = Markdown.render(ExportDocument(blocks: merger.blocks, source: .accessibility))
        var cursor = md.startIndex
        for m in msgs {
            for text in [m.who] + m.paras {
                let escaped = text
                guard let r = md.range(of: escaped, range: cursor..<md.endIndex) else { Issue.record("missing or out of order: \(text.prefix(40))"); return }
                #expect(md.split(separator: "\n").filter { $0 == escaped }.count == 1, "not exactly once: \(text.prefix(40))")
                cursor = r.upperBound
            }
        }
    }

    @Test func generatorMatchesTheTestPage() {
        // Values printed by running the page's own JavaScript (site/test/chat/index.html) in
        // Node, so a change to either generator shows up here.
        let m = Self.messages()
        #expect(m.count == 60)
        #expect([0, 1, 2, 17, 58, 59].map { m[$0].height } == [82, 208, 88, 228, 82, 209])
        #expect(m.map { String($0.paras.count) }.joined() == "131113121112111311131213121113111312131211121113111312111211")
        #expect(m[1].paras[0] == "Because short line quick number answer also stays part step keeps list order test top stays order next bottom shows plan first keeps left plan first question next line page because careful right again because line moves.")
        #expect(m[59].paras.last == "Careful step number chip line test box left also column scroll better plan number window step stays right simple bottom quick next scroll middle next quick page short scroll shows value answer small list.")
        #expect(m[1].who == "Assistant · message 2")
    }
}

@Suite("Exports stay in the chosen folder", .serialized)
struct ExportPrivacyTests {
    @Test func nothingIsWrittenOutsideTheChosenFolder() throws {
        let started = Date().addingTimeInterval(-1)
        let (cg, px) = renderPage(samplePage)
        let marker = "Unique marker \(UInt64.random(in: 1...UInt64.max))"
        let doc = ExportDocument(blocks: samplePage + [.paragraph([Inline(marker)])], source: .accessibility)
        let pages = PDFExport.pages(for: px, pageSize: .a4)
        let pdf = try #require(PDFExport.make(image: cg, pages: pages, lines: [TextLine(text: marker, x: 10, y: 10, width: 300, height: 20)], pageSize: .a4))
        let files: [(ext: String, data: Data)] = [("png", ImageBridge.png(cg)!), ("pdf", pdf), ("docx", Docx.make(doc)), ("md", Data(Markdown.render(doc).utf8))]
        // The chosen folder: a fresh one under the caches (the scan below skips it).
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Tallshot-build/export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "Notes - Trip plan - 2026-10-31 at 14.05 - Tallshot"
        let exts = files.map(\.ext)
        let written = ExportFiles.write(files, baseName: ExportFiles.uniqueBaseName(name, extensions: exts, folder: folder, ending: " - Tallshot"), folder: folder)
        #expect(written.error == nil)
        #expect(Set(written.files.keys) == ["png", "pdf", "docx", "md"])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == Set(exts.map { "\(name).\($0)" }))
        // A second export never overwrites: all four move to " 2" together, before the ending.
        let second = ExportFiles.uniqueBaseName(name, extensions: exts, folder: folder, ending: " - Tallshot")
        #expect(second == "Notes - Trip plan - 2026-10-31 at 14.05 2 - Tallshot")
        let again = ExportFiles.write(files, baseName: second, folder: folder)
        #expect(again.files["md"]?.lastPathComponent == "Notes - Trip plan - 2026-10-31 at 14.05 2 - Tallshot.md")
        // Nothing else holds the exported words or pixels. The search decodes PNGs, unpacks PDF
        // streams and unzips Word files (their data is compressed), and must first find them in
        // the chosen folder, or it proves nothing.
        let rows = DiskScanner.distinctiveRows(of: px)
        #expect(rows.allSatisfy { DiskScanner.changes($0) >= DiskScanner.minimumChanges }, "the pixel fingerprint must not be a plain row")
        let scanner = DiskScanner(texts: [marker], rows: rows)
        for ext in exts {
            let data = try Data(contentsOf: folder.appendingPathComponent("\(name).\(ext)"))
            #expect(!scanner.findings(in: data).isEmpty, "the search can't see the content of the .\(ext)")
        }
        let hits = scanner.scan(PrivacyTests.placesToSearch, topLevelOnly: [PrivacyTests.desktop], changedSince: started, skipping: [folder])
        for (path, what) in hits { Issue.record("export \(what.sorted().joined(separator: " and ")) found outside the chosen folder: \(path)") }
    }

    @Test func aFailedSaveKeepsAndReportsWhatWasSaved() throws {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Tallshot-build/export-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Someone else's file already has the PDF's name, so that write fails part way.
        let theirs = folder.appendingPathComponent("X - Tallshot.pdf")
        try Data("theirs".utf8).write(to: theirs)
        let files: [(ext: String, data: Data)] = [("png", Data([1, 2, 3])), ("pdf", Data([4])), ("md", Data([5]))]
        let written = ExportFiles.write(files, baseName: "X - Tallshot", folder: folder)
        #expect(written.error != nil)
        #expect(written.files.keys.sorted() == ["png"])
        #expect(try Data(contentsOf: theirs) == Data("theirs".utf8), "someone else's file must not be touched")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("X - Tallshot.md").path))
    }
    @Test func uniqueNamesWithoutTheEndingStillWork() throws {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Tallshot-build/export-uniq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("Plain.png"))
        #expect(ExportFiles.uniqueBaseName("Plain", extensions: ["png"], folder: folder, ending: " - Tallshot") == "Plain 2")
    }

    @Test func wordNumberedListsEachStartAtOne() {
        let doc = ExportDocument(blocks: [
            .listItem(level: 0, ordered: true, [Inline("one")]), .listItem(level: 0, ordered: true, [Inline("two")]),
            .paragraph([Inline("between")]),
            .listItem(level: 0, ordered: true, [Inline("again one")]),
        ], source: .accessibility)
        let data = Docx.make(doc)
        let xml = docxXML(data)
        #expect(xml.contains("<w:numId w:val=\"2\"/></w:numPr></w:pPr><w:r><w:t xml:space=\"preserve\">two"))
        #expect(xml.contains("<w:numId w:val=\"3\"/></w:numPr></w:pPr><w:r><w:t xml:space=\"preserve\">again one"))
        let numbering = String(decoding: Zip.entries(data)["word/numbering.xml"] ?? Data(), as: UTF8.self)
        #expect(numbering.contains("<w:num w:numId=\"3\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/>"))
    }
    @Test func wordKeepsLineBreaksAndDropsInvalidCharacters() {
        let doc = ExportDocument(blocks: [.paragraph([Inline("Hello\nWorld\u{FFFF}")])], source: .accessibility)
        let xml = docxXML(Docx.make(doc))
        #expect(xml.contains("<w:t xml:space=\"preserve\">Hello</w:t><w:br/><w:t xml:space=\"preserve\">World</w:t>"))
        #expect(!xml.contains("\u{FFFF}"))
    }
}
