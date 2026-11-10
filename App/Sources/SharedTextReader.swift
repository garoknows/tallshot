import AppKit
import ApplicationServices
import TallshotCore

/// Reads the text an app shares for the pane under the pointer, through Accessibility, for a
/// text capture (no scrolling, no pictures). Only the text element's role, frame, character
/// counts and value are read. `SharedTextCheck` decides whether the text is complete.
@MainActor
enum SharedTextReader {
    struct Result {
        var verdict: SharedTextCheck.Verdict
        /// The document, only when the verdict is `.complete`.
        var document: ExportDocument?
    }

    static func read(_ target: CaptureTarget) -> Result {
        // Tallshot's own windows: it would be asking itself, on the thread that must answer.
        guard target.pid != ProcessInfo.processInfo.processIdentifier else { return Result(verdict: .notText) }
        if target.kind == .webArea || target.kind == .webElement || target.isBrowserLike { return Result(verdict: .inWebPage) }
        guard let (element, insideWeb) = textArea(for: target) else { return Result(verdict: .notText) }
        AXUIElementSetMessagingTimeout(element, 2.0)   // a long terminal history can take a moment
        let text: String = TargetFinder.attribute(element, kAXValueAttribute) ?? ""
        let count = (TargetFinder.attribute(element, kAXNumberOfCharactersAttribute) as NSNumber?)?.intValue
        var visible: Range<Int>?
        if let v: AXValue = TargetFinder.attribute(element, kAXVisibleCharacterRangeAttribute) {
            var r = CFRange()
            if AXValueGetValue(v, .cfRange, &r), r.location >= 0, r.length >= 0 { visible = r.location..<(r.location + r.length) }
        }
        let facts = SharedTextFacts(role: "AXTextArea", insideWebPage: insideWeb, text: text, characterCount: count,
                                    visibleRange: visible, frame: TargetFinder.frame(element) ?? .zero, region: target.region)
        let verdict = SharedTextCheck.verdict(facts)
        guard verdict.isComplete else { return Result(verdict: verdict) }
        let preformatted = PlainTextDocument.isPreformatted(bundleID: target.bundleID, text: text)
        return Result(verdict: verdict, document: PlainTextDocument.document(from: text, preformatted: preformatted))
    }

    /// The text area for the pane: the element under the middle of the pane or one of its
    /// parents, else the biggest one just inside the pane's element. Also says whether it is
    /// inside a web page.
    private static func textArea(for target: CaptureTarget) -> (AXUIElement, Bool)? {
        let role = kAXTextAreaRole as String
        var found: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(system, Float(target.center.x), Float(target.center.y), &hit) == .success, var el = hit {
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            if pid == target.pid {
                for _ in 0..<8 {
                    AXUIElementSetMessagingTimeout(el, 0.5)
                    if TargetFinder.string(el, kAXRoleAttribute) == role { found = el; break }
                    guard let parent: AXUIElement = TargetFinder.attribute(el, kAXParentAttribute) else { break }
                    el = parent
                }
            }
        }
        if found == nil, let root = target.textRoot {
            // A few levels down from the pane (a scroll area holds its text view directly).
            var level = [root], best: (AXUIElement, CGFloat)?
            for _ in 0..<3 {
                var next: [AXUIElement] = []
                for el in level.prefix(60) {
                    AXUIElementSetMessagingTimeout(el, 0.5)
                    if TargetFinder.string(el, kAXRoleAttribute) == role, let f = TargetFinder.frame(el) {
                        let o = f.intersection(target.region)
                        let area = o.isNull ? 0 : o.width * o.height
                        if area > (best?.1 ?? 0) { best = (el, area) }
                    }
                    next += (TargetFinder.attribute(el, kAXChildrenAttribute) as [AXUIElement]?) ?? []
                }
                level = next
            }
            found = best?.0
        }
        guard let area = found else { return nil }
        return (area, insideWebPage(area))
    }

    private static func insideWebPage(_ element: AXUIElement) -> Bool {
        var el: AXUIElement? = element
        for _ in 0..<40 {
            guard let current = el else { return false }
            let r = TargetFinder.string(current, kAXRoleAttribute)
            if r == "AXWebArea" { return true }
            if r == (kAXWindowRole as String) || r == (kAXApplicationRole as String) { return false }
            el = TargetFinder.attribute(current, kAXParentAttribute)
        }
        return false
    }
}
