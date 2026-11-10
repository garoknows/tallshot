import CoreGraphics

/// One element found while walking an app's accessibility tree, for the accessibility probe.
/// Only its shape is kept: role, frame, how much text it holds and its class names, never the text.
public struct ProbeNode: Sendable, Equatable {
    public var role: String
    public var frame: CGRect?
    /// Characters of text the element shows itself (a static text's value), 0 for none.
    public var textLength: Int
    /// The web page's class names for it (Chromium's `AXDOMClassList`), if any.
    public var classes: [String]

    public init(role: String, frame: CGRect?, textLength: Int = 0, classes: [String] = []) {
        self.role = role; self.frame = frame; self.textLength = textLength; self.classes = classes
    }
}

/// What the probe found in a pane's tree: whether the text reaches beyond the screen, and whether
/// it runs without gaps. An app that keeps only the messages near the screen leaves empty space
/// (or nothing) where the rest would be; one that keeps the whole conversation has text all the way.
public struct ProbeReport: Sendable, Equatable {
    public enum Verdict: String, Sendable {
        case noText = "No text found in this pane."
        case nearScreenOnly = "Text only on and near the screen: the app keeps only what's nearby."
        case gaps = "Text above and below the screen, with empty stretches between: the app keeps only parts."
        case continuous = "Text runs well above and below the screen with no empty stretch: it may hold the whole conversation. Check that the first text in the pop-up is the chat's first message (it may also load older messages only when you scroll up)."
    }

    public var appName: String
    public var bundleID: String
    public var paneRole: String
    public var nodes: Int
    public var textBlocks: Int
    public var above: Int, onScreen: Int, below: Int
    /// The first and last text's position, in screens from the top of the pane (negative: above).
    public var textTop: Double, textBottom: Double
    /// The tallest stretch without text between the first and last text, in screens.
    public var largestGap: Double
    public var gapsOverOneScreen: Int
    public var headings: Int, lists: Int, listItems: Int, links: Int, codeBlocks: Int
    /// Class names that appear on at least 3 elements, most frequent first (at most 25).
    public var frequentClasses: [(name: String, count: Int)]
    /// The walk stopped at its time or size limit, so the counts are a lower bound.
    public var cutShort: Bool
    public var verdict: Verdict

    public static func == (a: ProbeReport, b: ProbeReport) -> Bool { a.text == b.text }

    public static func make(nodes: [ProbeNode], region: CGRect, appName: String, bundleID: String, paneRole: String,
                            cutShort: Bool) -> ProbeReport {
        let h = max(1, Double(region.height))
        let text = nodes.filter { $0.textLength > 0 }.compactMap { n in n.frame.flatMap { $0.height > 0 ? $0 : nil } }
        let above = text.filter { $0.maxY <= region.minY }.count
        let below = text.filter { $0.minY >= region.maxY }.count
        // Merge the text's vertical spans and find the largest empty stretch between them.
        var spans = text.map { (Double($0.minY), Double($0.maxY)) }.sorted { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for s in spans {
            if let last = merged.last, s.0 <= last.1 { merged[merged.count - 1].1 = max(last.1, s.1) } else { merged.append(s) }
        }
        spans = merged
        let gaps = zip(spans, spans.dropFirst()).map { ($1.0 - $0.1) / h }
        let top = spans.first.map { ($0.0 - Double(region.minY)) / h } ?? 0
        let bottom = spans.last.map { ($0.1 - Double(region.minY)) / h } ?? 0
        let largest = gaps.max() ?? 0
        var counts: [String: Int] = [:]
        for n in nodes { for c in Set(n.classes) where !c.isEmpty && c.count <= 40 { counts[c, default: 0] += 1 } }
        let frequent = counts.filter { $0.value >= 3 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(25).map { (name: $0.key, count: $0.value) }
        func count(_ role: String) -> Int { nodes.filter { $0.role == role }.count }
        let code = nodes.filter { n in n.role == "AXCodeStyleGroup" || n.classes.contains { $0 == "code" || $0.hasPrefix("language-") } }.count

        let verdict: Verdict
        if text.isEmpty { verdict = .noText }
        else if top > -0.5 && bottom < 1.5 { verdict = .nearScreenOnly }
        else if largest > 1 { verdict = .gaps }
        else { verdict = .continuous }

        return ProbeReport(appName: appName, bundleID: bundleID, paneRole: paneRole, nodes: nodes.count, textBlocks: text.count,
                           above: above, onScreen: text.count - above - below, below: below, textTop: top, textBottom: bottom,
                           largestGap: largest, gapsOverOneScreen: gaps.filter { $0 > 1 }.count,
                           headings: count("AXHeading"), lists: count("AXList"), listItems: count("AXListItem"), links: count("AXLink"),
                           codeBlocks: code, frequentClasses: frequent, cutShort: cutShort, verdict: verdict)
    }

    /// The report as plain text, for the clipboard. Holds no text from the app, only counts,
    /// positions and the page's class names.
    public var text: String {
        func f(_ d: Double) -> String { let r = (d * 10).rounded() / 10; return r == r.rounded() ? "\(Int(r))" : "\(r)" }
        var lines = [
            "Tallshot accessibility probe",
            "App: \(appName) (\(bundleID)), pane: \(paneRole)",
            "Verdict: \(verdict.rawValue)",
            "Elements walked: \(nodes)\(cutShort ? " (stopped at the limit, so these are lower bounds)" : "")",
            "Text blocks: \(textBlocks) (\(above) above the screen, \(onScreen) on it, \(below) below)",
            "Text runs from \(f(textTop)) to \(f(textBottom)) screens (0 = top of the pane, 1 = its bottom)",
            "Largest stretch with no text: \(f(largestGap)) screens; stretches over one screen: \(gapsOverOneScreen)",
            "Structure: \(headings) headings, \(lists) lists, \(listItems) list items, \(links) links, \(codeBlocks) code blocks",
        ]
        if !frequentClasses.isEmpty {
            lines.append("Frequent class names: " + frequentClasses.map { "\($0.name) ×\($0.count)" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
