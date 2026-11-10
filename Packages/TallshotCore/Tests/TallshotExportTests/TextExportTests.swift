import Foundation
import PDFKit
import Testing
import TallshotCore
import TallshotExport

@Suite("Text capture: the files")
struct TextExportTests {
    let plan = CaptureExport.Plan(png: true, pdf: true, docx: true, md: false, copyImage: true, copyText: false,
                                  pageSize: .letter, wordImage: true, baseName: "Ghostty - 2026-11-09 at 10.00 - Tallshot")

    @Test func theTextPlanMakesNoImageAndKeepsTheMarkdown() {
        let p = plan.forText
        #expect(!p.png && !p.copyImage && !p.wordImage)
        #expect(p.md, "saving a PNG becomes saving Markdown")
        #expect(p.copyText, "copying the image becomes copying the text")
        #expect(p.pdf && p.docx)
        #expect(p.extensions == ["pdf", "docx", "md"])
        // Saving and copying nothing stays nothing.
        let none = CaptureExport.Plan(png: false, pdf: false, docx: false, md: false, copyImage: false, copyText: false,
                                      pageSize: .a4, wordImage: false, baseName: "x").forText
        #expect(none.extensions.isEmpty && !none.copyText)
    }

    @Test func aLongTerminalHistoryBecomesEveryFile() throws {
        let history = (1...3_000).map { "\($0): build step \($0) ok" }.joined(separator: "\n")
        let doc = PlainTextDocument.document(from: history, preformatted: true)
        let built = CaptureExport.buildText(doc, plan: plan.forText)
        #expect(built.error == nil && built.notes.isEmpty)
        let files = Dictionary(uniqueKeysWithValues: built.files.map { ($0.ext, $0.data) })
        #expect(Set(files.keys) == ["pdf", "docx", "md"], "no PNG in a text capture")

        let mdData = try #require(files["md"])
        let md = String(decoding: mdData, as: UTF8.self)
        #expect(md.contains("1: build step 1 ok\n2: build step 2 ok") && md.contains("3000: build step 3000 ok"))
        #expect(!md.contains("!["), "no image link")
        #expect(built.clipboardText == md)

        let pdfData = try #require(files["pdf"])
        let pdf = try #require(PDFDocument(data: pdfData))
        #expect(pdf.pageCount > 20, "many pages: \(pdf.pageCount)")
        let words = pdf.string ?? ""
        #expect(words.contains("1: build step 1 ok") && words.contains("3000: build step 3000 ok"), "the first and last lines are in the PDF")
        #expect((pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) == "Tallshot capture")

        let docx = try #require(files["docx"])
        let xmlData = try #require(Zip.entries(docx)["word/document.xml"])
        let xml = String(decoding: xmlData, as: UTF8.self)
        #expect(xml.contains("3000: build step 3000 ok"))
    }

    @Test func oneHugeLineStillEnds() throws {
        let doc = PlainTextDocument.document(from: String(repeating: "x", count: 200_000), preformatted: true)
        let pdf = try #require(TextPDF.make(doc, pageSize: .a4))
        #expect((PDFDocument(data: pdf)?.pageCount ?? 0) > 1)
    }

    @Test func proseKeepsHeadingsBulletsAndWords() throws {
        let doc = PlainTextDocument.document(from: "Trip plan\n• Passport\n• Tickets", preformatted: false)
        let built = CaptureExport.buildText(doc, plan: plan.forText)
        let pdfData = try #require(built.files.first { $0.ext == "pdf" }?.data)
        let words = PDFDocument(data: pdfData)?.string ?? ""
        #expect(words.contains("Trip plan") && words.contains("Passport") && words.contains("Tickets"))
        #expect(built.clipboardText?.contains("- Passport") ?? false)
    }
}
