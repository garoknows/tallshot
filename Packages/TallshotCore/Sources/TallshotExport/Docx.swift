import Foundation
import TallshotCore

/// Builds a Word document (.docx) in memory: real heading styles, real nested bullet and
/// numbered lists, links, code blocks, and optionally the capture split into page-sized images.
///
/// Why not `NSAttributedString`'s built-in Word writer: it turns headings into plain bold
/// text, lists into tab-indented text, and drops links and images. A .docx is just a ZIP of a
/// few XML files, so Tallshot writes those files itself.
public enum Docx {
    /// One page-sized slice of the capture, as PNG data, with its size in pixels.
    public struct Picture {
        public var png: Data
        public var width: Int, height: Int
        public init(png: Data, width: Int, height: Int) { self.png = png; self.width = width; self.height = height }
    }

    public static func make(_ doc: ExportDocument, pictures: [Picture] = []) -> Data {
        var rels: [(id: String, type: String, target: String, external: Bool)] = [
            ("rIdStyles", "styles", "styles.xml", false),
            ("rIdNumbering", "numbering", "numbering.xml", false),
        ]
        var body = ""
        // Where the words came from.
        body += paragraph(style: "Source", runs: run(doc.source.note))
        for (i, p) in pictures.enumerated() {
            let id = "rIdImage\(i + 1)"
            rels.append((id, "image", "media/image\(i + 1).png", false))
            body += picture(id: id, index: i + 1, width: p.width, height: p.height)
        }
        var links = 0
        func runs(_ spans: [Inline]) -> String {
            spans.map { s in
                guard let link = s.link, !link.isEmpty else { return run(s.text) }
                links += 1
                let id = "rIdLink\(links)"
                rels.append((id, "hyperlink", link, true))
                return "<w:hyperlink r:id=\"\(id)\">" + run(s.text, style: "Hyperlink") + "</w:hyperlink>"
            }.joined()
        }
        for block in doc.blocks {
            switch block {
            case .heading(let level, let spans):
                body += paragraph(style: "Heading\(min(3, max(1, level)))", runs: runs(spans))
            case .paragraph(let spans):
                body += paragraph(style: nil, runs: runs(spans))
            case .listItem(let level, let ordered, let spans):
                body += "<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"\(min(8, max(0, level)))\"/>"
                    + "<w:numId w:val=\"\(ordered ? 2 : 1)\"/></w:numPr></w:pPr>\(runs(spans))</w:p>"
            case .code(let text):
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { run(String($0)) }
                body += paragraph(style: "Code", runs: lines.joined(separator: "<w:r><w:br/></w:r>"))
            }
        }
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(namespaces)><w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>\
        <w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
        let relsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(rels.map { "<Relationship Id=\"\($0.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\($0.type)\" Target=\"\(escape($0.target))\"\($0.external ? " TargetMode=\"External\"" : "")/>" }.joined())\
        </Relationships>
        """
        var entries: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(packageRels.utf8)),
            ("word/document.xml", Data(document.utf8)),
            ("word/_rels/document.xml.rels", Data(relsXML.utf8)),
            ("word/styles.xml", Data(styles.utf8)),
            ("word/numbering.xml", Data(numbering.utf8)),
        ]
        for (i, p) in pictures.enumerated() { entries.append(("word/media/image\(i + 1).png", p.png)) }
        return Zip.archive(entries.map { (name: $0.0, data: $0.1) })
    }

    // MARK: Pieces

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // XML 1.0 can't carry most control characters.
                if c.value < 0x20 && c != "\t" { continue }
                out.unicodeScalars.append(c)
            }
        }
        return out
    }

    static func run(_ text: String, style: String? = nil) -> String {
        let rpr = style.map { "<w:rPr><w:rStyle w:val=\"\($0)\"/></w:rPr>" } ?? ""
        return "<w:r>\(rpr)<w:t xml:space=\"preserve\">\(escape(text))</w:t></w:r>"
    }

    static func paragraph(style: String?, runs: String) -> String {
        let ppr = style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
        return "<w:p>\(ppr)\(runs)</w:p>"
    }

    /// An inline picture fitted to the text width (6.5 inches at most, 9 inches tall at most).
    static func picture(id: String, index: Int, width: Int, height: Int) -> String {
        let emuPerInch = 914_400.0
        var w = 6.5 * emuPerInch
        var h = w * Double(height) / Double(max(1, width))
        if h > 9 * emuPerInch { h = 9 * emuPerInch; w = h * Double(width) / Double(max(1, height)) }
        let cx = Int(w), cy = Int(h)
        return """
        <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
        <wp:docPr id="\(index)" name="Capture \(index)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
        <pic:nvPicPr><pic:cNvPr id="\(index)" name="image\(index).png"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """
    }

    static let namespaces = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" "
        + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
        + "xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" "
        + "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
        + "xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\""

    static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Default Extension="png" ContentType="image/png"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
    <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
    </Types>
    """

    static let packageRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    </Relationships>
    """

    static func heading(_ n: Int, size: Int) -> String {
        "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(n)\"><w:name w:val=\"heading \(n)\"/><w:basedOn w:val=\"Normal\"/>"
            + "<w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"80\"/>"
            + "<w:outlineLvl w:val=\"\(n - 1)\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"\(size)\"/></w:rPr></w:style>"
    }

    static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:cs="Arial"/><w:sz w:val="22"/></w:rPr></w:rPrDefault>\
    <w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
    \(heading(1, size: 36))\(heading(2, size: 30))\(heading(3, size: 26))\
    <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:spacing w:after="40"/><w:contextualSpacing/></w:pPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F2F3F5"/><w:spacing w:after="160" w:line="240" w:lineRule="auto"/></w:pPr>\
    <w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:cs="Courier New"/><w:sz w:val="19"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Source"><w:name w:val="Source"/><w:basedOn w:val="Normal"/>\
    <w:rPr><w:i/><w:color w:val="777777"/><w:sz w:val="18"/></w:rPr></w:style>\
    <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="2F6BFF"/><w:u w:val="single"/></w:rPr></w:style>\
    </w:styles>
    """

    static func levels(bullets: Bool) -> String {
        let marks = ["•", "◦", "▪"]
        return (0..<9).map { l in
            let fmt = bullets ? "bullet" : (l % 3 == 0 ? "decimal" : (l % 3 == 1 ? "lowerLetter" : "lowerRoman"))
            let text = bullets ? marks[l % 3] : "%\(l + 1)."
            return "<w:lvl w:ilvl=\"\(l)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(fmt)\"/><w:lvlText w:val=\"\(text)\"/>"
                + "<w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 * (l + 1))\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }.joined()
    }

    static let numbering = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>\(levels(bullets: true))</w:abstractNum>\
    <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>\(levels(bullets: false))</w:abstractNum>\
    <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>\
    </w:numbering>
    """
}
