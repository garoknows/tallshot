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
        guard let found = textArea(for: target) else { return Result(verdict: .notText) }
        let element = found.element
        AXUIElementSetMessagingTimeout(element, 2.0)   // a long terminal history can take a moment
        let text: String = TargetFinder.attribute(element, kAXValueAttribute) ?? ""
        let count = (TargetFinder.attribute(element, kAXNumberOfCharactersAttribute) as NSNumber?)?.intValue
        var visible: Range<Int>?
        if let v: AXValue = TargetFinder.attribute(element, kAXVisibleCharacterRangeAttribute) {
            var r = CFRange()
            if AXValueGetValue(v, .cfRange, &r), r.location >= 0, r.length >= 0 { visible = r.location..<(r.location + r.length) }
        }
        // Read only: nothing here scrolls, moves the pointer or changes the app.
        let facts = SharedTextFacts(role: "AXTextArea", insideWebPage: insideWebPage(element), text: text, characterCount: count,
                                    visibleRange: visible, frame: TargetFinder.frame(element) ?? .zero, region: target.region,
                                    underPaneCenter: found.underCenter)
        let verdict = SharedTextCheck.verdict(facts)
        guard verdict.isComplete else { return Result(verdict: verdict) }
        let preformatted = PlainTextDocument.isPreformatted(bundleID: target.bundleID, text: text)
        return Result(verdict: verdict, document: PlainTextDocument.document(from: text, preformatted: preformatted))
    }

    /// The text area for the pane: the element under the middle of the pane or one of its
    /// parents; else the one overlapping the pane most, a few levels below that element, the
    /// pane's element or the app's focused window.
    private static func textArea(for target: CaptureTarget) -> (element: AXUIElement, underCenter: Bool)? {
        let role = kAXTextAreaRole as String
        func isTextArea(_ el: AXUIElement) -> Bool {
            AXUIElementSetMessagingTimeout(el, 0.5)
            return TargetFinder.string(el, kAXRoleAttribute) == role
        }
        var hit: AXUIElement?
        var starts: [AXUIElement] = []
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(target.center.x), Float(target.center.y), &hit) == .success,
           var el = hit {
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            if pid == target.pid {
                starts.append(el)
                for _ in 0..<8 {
                    if isTextArea(el) { return (el, true) }
                    guard let parent: AXUIElement = TargetFinder.attribute(el, kAXParentAttribute) else { break }
                    el = parent
                }
            }
        }
        if let root = target.textRoot { starts.append(root) }
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        if let window: AXUIElement = TargetFinder.attribute(app, kAXFocusedWindowAttribute) { starts.append(window) }
        var best: (AXUIElement, CGFloat)?
        var visited = 0
        for start in starts {
            var level = [start]
            for _ in 0..<5 where visited < 400 {
                var next: [AXUIElement] = []
                for el in level.prefix(80) {
                    visited += 1
                    if isTextArea(el), let f = TargetFinder.frame(el) {
                        let o = f.intersection(target.region)
                        let area = o.isNull ? 0 : o.width * o.height
                        if area > (best?.1 ?? 0) { best = (el, area) }
                    }
                    next += (TargetFinder.attribute(el, kAXChildrenAttribute) as [AXUIElement]?) ?? []
                }
                level = next
            }
        }
        return best.map { ($0.0, false) }
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
