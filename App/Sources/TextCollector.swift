import AppKit
import ApplicationServices
import TallshotCore

/// Reads the words of the pane through the accessibility tree while it is captured: headings,
/// paragraphs, list items, links and code blocks, in order. At each scroll step it takes the
/// blocks that are on screen, and `SnapshotMerger` joins the steps, dropping repeats.
/// Only used when an export needs the text (Markdown, Word, or copying as text).
@MainActor
final class TextCollector {
    let root: AXUIElement
    let region: CGRect
    /// The app's bundle ID: a terminal's or code editor's text is kept as one exact code block.
    let bundleID: String?
    private(set) var merger = SnapshotMerger()
    /// Which readings hit their limit, so a cut-short export says so (1.1.4).
    private(set) var log = TextReadingLog()
    private var visited = 0
    private var maxElements = 4_000
    private var deadline = 0.0
    private var hitLimit = false

    /// Roles that are controls, not content: their text is left out.
    static let skip: Set<String> = ["AXButton", "AXTextField", "AXToolbar", "AXMenu", "AXMenuBar", "AXMenuItem", "AXMenuButton",
                                    "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXScrollBar", "AXSlider", "AXTabGroup",
                                    "AXImage", "AXComboBox", "AXDisclosureTriangle", "AXIncrementor", "AXSearchField", "AXSplitter"]
    static let inline: Set<String> = ["AXStaticText", "AXLink", "AXListMarker"]

    init(root: AXUIElement, region: CGRect, bundleID: String? = nil) {
        self.root = root
        self.region = region
        self.bundleID = bundleID
        AXUIElementSetMessagingTimeout(root, 0.5)
    }

    var document: ExportDocument { ExportDocument(blocks: merger.blocks, source: .accessibility, missingNote: log.note) }

    /// Takes one snapshot of what's on screen now, at a scroll step. Bounded to about 0.3 s and
    /// 4,000 elements, so a slow app can't hold up the capture; a reading that hits the limit is
    /// recorded.
    func snapshot() {
        read(seconds: 0.3, elements: 4_000)
        log.reading(cutShort: hitLimit)
    }

    /// One longer reading once the capture has finished, where the last step's reading was taken.
    func finalSnapshot() {
        read(seconds: 2.0, elements: 40_000)
        log.finalReading(cutShort: hitLimit)
    }

    private func read(seconds: Double, elements: Int) {
        visited = 0
        hitLimit = false
        maxElements = elements
        deadline = ProcessInfo.processInfo.systemUptime + seconds
        var blocks: [Block] = []
        visit(root, listDepth: -1, into: &blocks)
        merger.add(blocks)
    }

    private var outOfTime: Bool { visited > maxElements || ProcessInfo.processInfo.systemUptime > deadline }

    private func onScreen(_ el: AXUIElement) -> Bool {
        guard let f = TargetFinder.frame(el) else { return true }
        return f.intersects(region)
    }

    private func children(_ el: AXUIElement) -> [AXUIElement] {
        TargetFinder.attribute(el, kAXChildrenAttribute) ?? []
    }

    private func role(_ el: AXUIElement) -> String { TargetFinder.string(el, kAXRoleAttribute) ?? "" }

    private func visit(_ el: AXUIElement, listDepth: Int, into out: inout [Block]) {
        guard !outOfTime else { hitLimit = true; return }
        visited += 1
        let r = role(el)
        if Self.skip.contains(r) { return }
        switch r {
        case "AXHeading":
            guard onScreen(el) else { return }
            let level = (TargetFinder.attribute(el, kAXValueAttribute) as NSNumber?)?.intValue ?? 2
            let text = plain(el)
            if !text.isEmpty { out.append(.heading(level: min(6, max(1, level)), [Inline(text)])) }
        case "AXList":
            for item in children(el) { listItem(item, depth: listDepth + 1, into: &out) }
        case "AXTextArea":
            // A document view (Notes, TextEdit): its whole text, split into paragraphs. A small
            // text area is a message box, and is left out.
            guard let f = TargetFinder.frame(el), f.height > region.height * 0.4,
                  let value: String = TargetFinder.attribute(el, kAXValueAttribute) else { return }
            if PlainTextDocument.isPreformatted(bundleID: bundleID, text: value) {
                let t = PlainTextDocument.clean(value)
                if !t.isEmpty { out.append(.code(t)) }
            } else {
                out += PlainTextDocument.prose(value)
            }
        default:
            if isCode(el, role: r) {
                guard onScreen(el) else { return }
                let text = plain(el, separator: "")
                if !text.isEmpty { out.append(.code(text)) }
                return
            }
            if Self.inline.contains(r) {
                guard onScreen(el) else { return }
                let spans = inlines(el)
                if !spans.isEmpty { out.append(.paragraph(spans)) }
                return
            }
            let kids = children(el)
            // A container of only text and links is one paragraph.
            if !kids.isEmpty, kids.allSatisfy({ Self.inline.contains(role($0)) }) {
                guard onScreen(el) else { return }
                let spans = kids.flatMap(inlines)
                if !spans.isEmpty { out.append(.paragraph(spans)) }
                return
            }
            if let f = TargetFinder.frame(el), !f.intersects(region), r != "AXWebArea", r != "AXScrollArea" { return }
            for k in kids { visit(k, listDepth: listDepth, into: &out) }
        }
    }

    private func listItem(_ item: AXUIElement, depth: Int, into out: inout [Block]) {
        guard !outOfTime else { return }
        visited += 1
        let kids = children(item)
        var spans: [Inline] = [], nested: [AXUIElement] = []
        var ordered = false
        for k in kids {
            let r = role(k)
            if r == "AXList" { nested.append(k); continue }
            if r == "AXListMarker" {
                let m = plain(k)
                ordered = m.first?.isNumber ?? false
                continue
            }
            spans += inlines(k)
        }
        if onScreen(item), !spans.isEmpty {
            out.append(.listItem(level: max(0, depth), ordered: ordered, spans))
        }
        for n in nested { visit(n, listDepth: depth, into: &out) }
    }

    private func isCode(_ el: AXUIElement, role: String) -> Bool {
        if (TargetFinder.string(el, kAXSubroleAttribute) ?? "") == "AXCodeStyleGroup" { return true }
        let desc = (TargetFinder.string(el, kAXRoleDescriptionAttribute) ?? "").lowercased()
        return role == "AXGroup" && (desc == "code" || desc.hasPrefix("code "))
    }

    /// The text of an element and its descendants, as inline runs (links keep their address).
    private func inlines(_ el: AXUIElement) -> [Inline] {
        guard !outOfTime else { return [] }
        visited += 1
        let r = role(el)
        if Self.skip.contains(r) || r == "AXListMarker" { return [] }
        if r == "AXLink" {
            let url: URL? = TargetFinder.attribute(el, kAXURLAttribute)
            let text = plain(el)
            return text.isEmpty ? [] : [Inline(text, link: url?.absoluteString)]
        }
        if r == "AXStaticText" {
            let v: String = TargetFinder.attribute(el, kAXValueAttribute) ?? ""
            return v.isEmpty ? [] : [Inline(v)]
        }
        return children(el).flatMap(inlines)
    }

    private func plain(_ el: AXUIElement, separator: String = "") -> String {
        let v: String? = TargetFinder.attribute(el, kAXValueAttribute)
        if let v, !v.isEmpty, role(el) != "AXHeading" { return v }
        let title: String? = TargetFinder.attribute(el, kAXTitleAttribute)
        if let title, !title.isEmpty { return title }
        return inlines(el).map(\.text).joined(separator: separator).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
