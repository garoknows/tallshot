/// The words of a capture, with their structure: what the Markdown and Word exports are made of.
/// Built either from the app's accessibility tree (exact text and real structure) or from text
/// recognized in the finished image (rebuilt from the layout).

/// A run of text, optionally a link.
public struct Inline: Equatable, Hashable, Sendable {
    public var text: String
    public var link: String?
    public init(_ text: String, link: String? = nil) { self.text = text; self.link = link }
}

public enum Block: Equatable, Hashable, Sendable {
    case heading(level: Int, [Inline])
    case paragraph([Inline])
    /// `level` 0 is the outermost list.
    case listItem(level: Int, ordered: Bool, [Inline])
    case code(String)

    /// The plain words, for comparing and searching.
    public var plainText: String {
        switch self {
        case .heading(_, let s), .paragraph(let s), .listItem(_, _, let s): s.map(\.text).joined()
        case .code(let c): c
        }
    }
}

/// Where the words came from. Recorded in every export.
public enum TextSource: String, Sendable {
    case accessibility
    case recognized

    public var note: String {
        switch self {
        case .accessibility: "Text from the app's accessibility tree (exact text)."
        case .recognized: "Text recognized from the image on this Mac (may contain mistakes)."
        }
    }
}

public struct ExportDocument: Equatable, Sendable {
    public var blocks: [Block]
    public var source: TextSource
    public init(blocks: [Block], source: TextSource) { self.blocks = blocks; self.source = source }

    /// True when there's enough text to be worth exporting.
    public var hasText: Bool { blocks.contains { !$0.plainText.trimmingWhitespace.isEmpty } }
}

// MARK: Markdown

public enum Markdown {
    /// The Markdown for a document. `imageFile` (the PNG's file name) adds the image at the top.
    public static func render(_ doc: ExportDocument, imageFile: String? = nil) -> String {
        var out: [String] = []
        if let imageFile { out.append("![Tallshot capture](<\(imageFile)>)"); out.append("") }
        out.append("_\(doc.source.note)_")
        var previousWasList = false
        for block in doc.blocks {
            let isList: Bool
            if case .listItem = block { isList = true } else { isList = false }
            // A blank line between blocks, except between items of the same list.
            if !(isList && previousWasList) { out.append("") }
            switch block {
            case .heading(let level, let spans):
                out.append(String(repeating: "#", count: min(6, max(1, level))) + " " + inline(spans))
            case .paragraph(let spans):
                out.append(inline(spans))
            case .listItem(let level, let ordered, let spans):
                out.append(String(repeating: "  ", count: max(0, level)) + (ordered ? "1. " : "- ") + inline(spans))
            case .code(let text):
                // A fence longer than any run of backticks in the code, so the code can't close it.
                let longest = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line in line.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0 }.max() ?? 0
                let fence = String(repeating: "`", count: max(3, longest + 1))
                out.append(fence); out.append(text); out.append(fence)
            }
            previousWasList = isList
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func inline(_ spans: [Inline]) -> String {
        spans.map { s in
            let t = escape(s.text)
            guard let link = s.link.flatMap(safeLink) else { return t }
            return "[\(t)](\(link))"
        }.joined()
    }

    /// Escapes the few characters that would change meaning at the start of a line or in a link.
    static func escape(_ s: String) -> String {
        var t = s.replacingAll("\n", with: " ")
        for c in ["\\", "[", "]", "*", "_", "`", "<"] { t = t.replacingAll(c, with: "\\" + c) }
        if let f = t.first, "#>+-|".contains(f) { t = "\\" + t }
        // "2024. Results" would start a numbered list.
        let digits = t.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty, let next = t.dropFirst(digits.count).first, next == "." || next == ")" {
            t = digits + "\\" + t.dropFirst(digits.count)
        }
        return t
    }

    /// Web and mail links only, with the characters that would end the link encoded.
    static func safeLink(_ link: String) -> String? {
        let lower = link.lowercased()
        guard ["http://", "https://", "mailto:"].contains(where: { lower.hasPrefix($0) }) else { return nil }
        var t = link
        for (c, code) in [("\n", ""), ("\r", ""), (" ", "%20"), ("(", "%28"), (")", "%29"), ("<", "%3C"), (">", "%3E")] {
            t = t.replacingAll(c, with: code)
        }
        return t
    }
}

// MARK: Merging accessibility snapshots

/// Merges the text seen at each scroll step into one document, dropping what was seen before.
/// Each snapshot is the blocks visible at one step, in order; consecutive snapshots overlap.
public struct SnapshotMerger: Sendable {
    public private(set) var blocks: [Block] = []
    public init() {}

    public mutating func add(_ snapshot: [Block]) {
        let snap = snapshot.filter { !$0.plainText.trimmingWhitespace.isEmpty }
        guard !snap.isEmpty else { return }
        guard !blocks.isEmpty else { blocks = snap; return }
        // The longest run at the end of what we have that starts the new snapshot.
        let maxK = min(blocks.count, snap.count)
        for k in stride(from: maxK, through: 1, by: -1) where Array(blocks.suffix(k)) == Array(snap.prefix(k)) {
            blocks += snap.dropFirst(k)
            return
        }
        // The snapshot may start a little above where we are: find our last block in it.
        if let last = blocks.last, let i = snap.lastIndex(of: last) {
            blocks += snap[(i + 1)...]
            return
        }
        // No overlap at all (a jump): add what isn't among the recent blocks.
        let recent = Set(blocks.suffix(400))
        blocks += snap.filter { !recent.contains($0) }
    }
}

// MARK: Rebuilding structure from recognized text

/// One line of recognized text, in image pixels (origin at the top-left).
public struct TextLine: Equatable, Sendable {
    public var text: String
    public var x: Double, y: Double, width: Double, height: Double
    /// The line sits on a shaded box (a code block).
    public var onShade: Bool
    public init(text: String, x: Double, y: Double, width: Double, height: Double, onShade: Bool = false) {
        self.text = text; self.x = x; self.y = y; self.width = width; self.height = height; self.onShade = onShade
    }
}

public enum LayoutReader {
    static let bulletMarks: [Character] = ["•", "◦", "▪", "‣", "⁃", "-", "–", "—", "*", "·", "●", "○"]

    /// Rebuilds headings, paragraphs, nested bullets and code blocks from text lines.
    public static func blocks(from input: [TextLine]) -> [Block] {
        let lines = mergeSameRow(input.filter { !$0.text.trimmingWhitespace.isEmpty })
        guard !lines.isEmpty else { return [] }
        let body = lines.filter { !$0.onShade }.map(\.height).sorted()
        let typical = body.isEmpty ? lines.map(\.height).sorted()[lines.count / 2] : body[body.count / 2]
        // Letter width is a steadier sign of a bigger font than box height, which changes with
        // letters like g and y; bold headings are wider still.
        func charWidth(_ l: TextLine) -> Double { l.width / Double(max(1, l.text.count)) }
        let widths = lines.filter { !$0.onShade && $0.text.count >= 8 }.map(charWidth).sorted()
        let typicalWidth = widths.isEmpty ? typical * 0.5 : widths[widths.count / 2]
        func size(_ l: TextLine) -> Double { max(l.height / typical, l.text.count >= 3 ? charWidth(l) / typicalWidth : 0) }

        // Indent levels for bullets: distinct left edges, smallest first.
        var bulletXs: [Double] = []
        for l in lines where bullet(l.text) != nil {
            if !bulletXs.contains(where: { abs($0 - l.x) < typical * 0.8 }) { bulletXs.append(l.x) }
        }
        bulletXs.sort()

        var out: [Block] = []
        var para: [String] = [], paraX = 0.0, lastBottom = -1e9
        var code: [TextLine] = []
        func flushPara() { if !para.isEmpty { out.append(.paragraph([Inline(para.joined(separator: " "))])); para = [] } }
        func flushCode() {
            guard !code.isEmpty else { return }
            let left = code.map(\.x).min() ?? 0
            let charW = max(1, (code.map { $0.width / Double(max(1, $0.text.count)) }.sorted())[code.count / 2])
            out.append(.code(code.map { String(repeating: " ", count: max(0, Int(($0.x - left) / charW + 0.3))) + $0.text }
                .joined(separator: "\n")))
            code = []
        }
        for l in lines {
            let gap = l.y - lastBottom
            defer { lastBottom = l.y + l.height }
            if l.onShade { flushPara(); code.append(l); continue }
            flushCode()
            let r = size(l)
            if r >= 1.3 && bullet(l.text) == nil {
                flushPara()
                let level = r >= 1.85 ? 1 : (r >= 1.4 ? 2 : 3)
                out.append(.heading(level: level, [Inline(l.text.trimmingWhitespace)]))
                continue
            }
            if let (ordered, rest) = bullet(l.text) {
                flushPara()
                let level = bulletXs.firstIndex { abs($0 - l.x) < typical * 0.8 } ?? 0
                out.append(.listItem(level: level, ordered: ordered, [Inline(rest)]))
                continue
            }
            // A line that continues the previous bullet (indented under its text, close below).
            if para.isEmpty, case .listItem(let level, let ordered, let spans)? = out.last, gap < typical * 0.9,
               l.x > (bulletXs[safe: level] ?? 0) + typical * 0.4 {
                out[out.count - 1] = .listItem(level: level, ordered: ordered, [Inline(spans.map(\.text).joined() + " " + l.text.trimmingWhitespace)])
                continue
            }
            // Same paragraph: close below and starting at about the same place.
            if !para.isEmpty && (gap > typical * 0.9 || abs(l.x - paraX) > typical * 1.5) { flushPara() }
            if para.isEmpty { paraX = l.x }
            para.append(l.text.trimmingWhitespace)
        }
        flushPara(); flushCode()
        return out
    }

    /// (ordered, text after the marker) when the line starts with a bullet or a number.
    static func bullet(_ text: String) -> (Bool, String)? {
        let t = text.trimmingWhitespace
        guard let first = t.first else { return nil }
        if bulletMarks.contains(first), t.count > 1 {
            let rest = t.dropFirst()
            guard rest.first == " " || first == "•" || first == "◦" || first == "▪" || first == "●" else { return nil }
            return (false, String(rest).trimmingWhitespace)
        }
        var digits = 0
        for c in t { if c.isNumber { digits += 1 } else { break } }
        if digits > 0 && digits <= 3, t.count > digits + 1 {
            let i = t.index(t.startIndex, offsetBy: digits)
            if t[i] == "." || t[i] == ")", t[t.index(after: i)] == " " {
                return (true, String(t[t.index(after: i)...]).trimmingWhitespace)
            }
        }
        return nil
    }

    /// Joins pieces that sit on the same visual row (Vision sometimes splits a line).
    static func mergeSameRow(_ lines: [TextLine]) -> [TextLine] {
        let sorted = lines.sorted { abs($0.y - $1.y) > min($0.height, $1.height) * 0.5 ? $0.y < $1.y : $0.x < $1.x }
        var out: [TextLine] = []
        for l in sorted {
            if var last = out.last, abs(last.y - l.y) < min(last.height, l.height) * 0.5, l.x >= last.x, l.onShade == last.onShade {
                last.text += " " + l.text
                last.width = max(last.x + last.width, l.x + l.width) - last.x
                last.height = max(last.height, l.height)
                out[out.count - 1] = last
            } else {
                out.append(l)
            }
        }
        return out
    }
}

// MARK: PDF page breaks

public enum PageBreaker {
    /// Splits an image `height` pixels tall into pages of at most `pageHeight` pixels, cutting
    /// in a blank row where one is near the end of the page (within `lookBack` of it), so a
    /// line of text isn't sliced in half. `isBlank(y)` says whether row y is blank.
    public static func pages(height: Int, pageHeight: Int, lookBack: Double = 0.15, isBlank: (Int) -> Bool) -> [Range<Int>] {
        precondition(pageHeight > 0)
        var out: [Range<Int>] = []
        var start = 0
        while start < height {
            var end = min(height, start + pageHeight)
            if end < height {
                // The blank run closest to the page end, cut in its middle.
                let floor = max(start + 1, end - Int(Double(pageHeight) * lookBack))
                var y = end - 1
                while y >= floor && !isBlank(y) { y -= 1 }
                if y >= floor {
                    var top = y
                    while top - 1 >= floor && isBlank(top - 1) { top -= 1 }
                    end = (top + y + 1) / 2 + 1
                }
            }
            out.append(start..<end)
            start = end
        }
        return out
    }

    /// Row y of `image` is blank: (almost) all one color.
    public static func blankRows(_ image: PixelImage) -> [Bool] {
        (0..<image.height).map { y in
            let first = image[0, y]
            var differ = 0
            let allowed = image.width / 200
            for x in 0..<image.width where image[x, y] != first {
                differ += 1
                if differ > allowed { return false }
            }
            return true
        }
    }
}

// MARK: Small helpers (no Foundation in this package)

extension String {
    var trimmingWhitespace: String {
        var s = Substring(self)
        while let f = s.first, f.isWhitespace { s = s.dropFirst() }
        while let l = s.last, l.isWhitespace { s = s.dropLast() }
        return String(s)
    }

    func replacingAll(_ target: String, with replacement: String) -> String {
        guard !target.isEmpty else { return self }
        var out = "", rest = Substring(self)
        while let r = rest.range(of: target) {
            out += rest[..<r.lowerBound] + replacement
            rest = rest[r.upperBound...]
        }
        return out + rest
    }
}

extension Substring {
    func range(of target: String) -> Range<Substring.Index>? {
        guard !target.isEmpty, count >= target.count else { return nil }
        var i = startIndex
        while i < endIndex {
            if self[i...].hasPrefix(target) { return i..<index(i, offsetBy: target.count) }
            i = index(after: i)
        }
        return nil
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
