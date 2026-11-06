import AppKit
import ApplicationServices
import TallshotCore

/// What kind of area was picked.
enum RegionKind: String {
    /// A real scrolling area the app reports through Accessibility.
    case scrollArea
    /// A web element whose content is taller than its box: a scrolling column inside a page.
    case webElement
    /// A browser tab's page (no tabs or toolbar), used when no scrolling area was found.
    case webArea
    /// The whole window: the last fallback.
    case window
}

/// What to capture: one window, and the scrolling area inside it.
struct CaptureTarget {
    /// The capture region in global screen points, origin at the top-left of the main display.
    var region: CGRect
    var windowID: CGWindowID
    var windowFrame: CGRect
    var pid: pid_t
    var kind: RegionKind
    var appName: String
    var bundleID: String?
    /// Where scroll events are sent. The middle of a real scrolling area; for a fallback, the
    /// spot the user pointed at (the part that scrolls may not be in the middle of the window).
    var scrollPoint: CGPoint
    /// The area's vertical scroll bar, when the app lets Tallshot set its position directly.
    var scrollBar: AXUIElement?
    /// Height of the scrolled content in points, when the app reports it.
    var contentHeight: CGFloat?
    /// Browsers and Chromium/Electron apps: start with small steps (they can overshoot).
    var isBrowserLike = false
    /// Crop the result to the columns that moved: the region is a fallback in pane mode.
    var cropToMovement = false
    /// The accessibility element of the pane, for reading its text during the capture.
    var textRoot: AXUIElement?

    var isScrollArea: Bool { kind == .scrollArea }
    var center: CGPoint { CGPoint(x: region.midX, y: region.midY) }
}

/// Chromium and Electron apps hide their accessibility tree until an assistive app asks for it.
/// This turns it on for one app and puts back what it changed when the capture is over.
@MainActor
final class AccessibilitySwitch {
    /// Chromium-based browsers that build their tree for `AXEnhancedUserInterface`.
    static let chromiumBrowsers: [String] = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "company.thebrowser.Browser", "company.thebrowser.dia", "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.brave.Browser", "com.brave.Browser.beta",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    let app: AXUIElement
    private var enhancedBefore: Bool?
    private(set) var changedSomething = false

    init(pid: pid_t, bundleID: String?) {
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        // Electron's switch. Apps that don't know it just say "unsupported".
        if !Self.bool(app, "AXManualAccessibility") {
            if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success { changedSomething = true }
        }
        // Chromium browsers' switch. Remember the old value: it can disturb window animations.
        if let id = bundleID, Self.chromiumBrowsers.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) {
            let before = Self.bool(app, "AXEnhancedUserInterface")
            enhancedBefore = before
            if !before, AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success {
                changedSomething = true
            }
        }
    }

    /// Puts `AXEnhancedUserInterface` back the way it was.
    func restore() {
        guard let before = enhancedBefore, !before else { return }
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        enhancedBefore = nil
    }

    static func bool(_ el: AXUIElement, _ name: String) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return false }
        return (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? false)
    }
}

/// Finds the scrolling area under the pointer through the Accessibility interface.
@MainActor
enum TargetFinder {
    /// Height of the main display, for converting between AppKit's bottom-left screen
    /// coordinates and the top-left coordinates that Accessibility and CoreGraphics use.
    static var mainHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toAppKit(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    static func pointerLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// The window under `point`, or the front window when there is no point (see `WindowChoice`).
    static func window(at point: CGPoint?) -> WindowInfo? {
        let windows = windowList()
        let i = WindowChoice.index(frames: windows.map(\.bounds), owners: windows.map(\.pid), pointer: point,
                                   front: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                   own: ProcessInfo.processInfo.processIdentifier)
        return i.map { windows[$0] }
    }

    /// The target under `point` (nil: in the front window), or a fallback. Turns on Chromium/Electron accessibility first
    /// and retries for up to `waitMs` while the app builds its tree. The returned switch must be
    /// restored when the capture is over.
    static func find(at point: CGPoint?, mode: CaptureMode = .pane, waitMs: Int = 400) async -> (CaptureTarget, AccessibilitySwitch?)? {
        guard let window = window(at: point) else { return nil }
        let running = NSRunningApplication(processIdentifier: window.pid)
        let bundleID = running?.bundleIdentifier
        let own = window.pid == ProcessInfo.processInfo.processIdentifier
        // From the menu, or over no window: look at the middle of the window instead.
        let probe = point.flatMap { window.bounds.contains($0) ? $0 : nil } ?? CGPoint(x: window.bounds.midX, y: window.bounds.midY)

        var hit: Hit? = nil
        var axSwitch: AccessibilitySwitch? = nil
        if !own {
            axSwitch = AccessibilitySwitch(pid: window.pid, bundleID: bundleID)
            hit = lookUp(at: probe, pid: window.pid, window: window.bounds)
            // A tree that was just switched on takes a moment to build.
            var waited = 0
            while (hit == nil || hit?.kind == .webArea) && waited < waitMs && (axSwitch?.changedSomething ?? false || hit == nil) {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 50
                if let again = lookUp(at: probe, pid: window.pid, window: window.bounds) {
                    hit = again
                    if again.kind == .scrollArea || again.kind == .webElement { break }
                }
            }
        }

        var region = window.bounds
        var kind = RegionKind.window
        if mode == .pane, let hit {
            let clipped = hit.frame.intersection(window.bounds)
            if clipped.width >= 60 && clipped.height >= 60 { region = clipped; kind = hit.kind }
        }
        // Keep to the part that is on a screen, so the pointer can sit in the middle of it.
        if let screen = screenFrames().first(where: { $0.contains(CGPoint(x: region.midX, y: region.midY)) }) {
            region = region.intersection(screen)
        }
        region = region.integral
        guard region.width >= 20 && region.height >= 20 else { axSwitch?.restore(); return nil }
        let inside = region.insetBy(dx: 4, dy: 4)
        let scrollPoint = (kind == .webArea || kind == .window) && inside.contains(probe) ? probe : CGPoint(x: region.midX, y: region.midY)
        let target = CaptureTarget(region: region, windowID: window.id, windowFrame: window.bounds, pid: window.pid, kind: kind,
                                   appName: window.owner, bundleID: bundleID, scrollPoint: scrollPoint,
                                   scrollBar: kind == .scrollArea ? hit?.scrollBar : nil, contentHeight: hit?.contentHeight,
                                   isBrowserLike: isBrowserLike(bundleID: bundleID, app: running),
                                   cropToMovement: mode == .pane && (kind == .webArea || kind == .window
                                       || (kind == .scrollArea && isBrowserLike(bundleID: bundleID, app: running)
                                           && PanePicker.scrollAreaFillsWindow(region, window: window.bounds))),
                                   textRoot: hit?.element)
        return (target, axSwitch)
    }

    /// Browsers and Chromium/Electron apps, which scroll with momentum and smooth animation.
    static func isBrowserLike(bundleID: String?, app: NSRunningApplication?) -> Bool {
        if let id = bundleID {
            if AccessibilitySwitch.chromiumBrowsers.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) { return true }
            if ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox"].contains(id) { return true }
        }
        if let url = app?.bundleURL?.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
           FileManager.default.fileExists(atPath: url.path) { return true }
        return false
    }

    /// What a capture's file name may say. A browser whose private windows can't be told apart
    /// has nothing read from it. Only a field's type is checked, never what's typed in it.
    static func nameFacts(for target: CaptureTarget) -> CaptureName.Facts {
        let running = NSRunningApplication(processIdentifier: target.pid)
        let kind = CaptureName.kind(bundleID: target.bundleID, isBrowser: isWebBrowser(bundleID: target.bundleID, app: running))
        var facts = CaptureName.Facts(appName: target.appName, kind: kind,
                                      englishLanguage: Locale.preferredLanguages.first?.hasPrefix("en") ?? false)
        guard kind != .uncheckableBrowser else { return facts }
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        if let focused: AXUIElement = attribute(app, kAXFocusedUIElementAttribute),
           string(focused, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) {
            facts.passwordFieldFocused = true
            return facts
        }
        guard let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute),
              let window = windows.first(where: { frame($0).map { sameFrame($0, target.windowFrame) } ?? false }) else { return facts }
        let title = string(window, kAXTitleAttribute)
        facts.title = title
        switch kind {
        case .checkableBrowser:
            if let page = webArea(for: target, window: window) {
                facts.pageURL = (attribute(page, kAXURLAttribute) as URL?)?.absoluteString ?? string(page, kAXURLAttribute)
            }
        case .ordinary:
            // Many Electron apps name the window after themselves and the page after what's open.
            if title?.isEmpty ?? true || title == target.appName, let page = webArea(for: target, window: window) {
                let named = [string(page, kAXTitleAttribute), string(page, kAXDescriptionAttribute)].compactMap { $0 }
                facts.title = named.first { !$0.isEmpty } ?? title
            }
        case .uncheckableBrowser:
            break
        }
        return facts
    }

    private static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// Any app macOS knows can open web links, plus the browsers already known by name.
    private static func isWebBrowser(bundleID: String?, app: NSRunningApplication?) -> Bool {
        if let id = bundleID {
            if AccessibilitySwitch.chromiumBrowsers.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) { return true }
            if ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox"].contains(id) { return true }
        }
        guard let bundle = app?.bundleURL?.standardizedFileURL, let web = URL(string: "https://example.com") else { return false }
        return NSWorkspace.shared.urlsForApplications(toOpen: web).contains { $0.standardizedFileURL == bundle }
    }

    /// The web page holding the captured area: above the pane, or else found below the window
    /// without going inside any page. Gives up rather than hold up the capture.
    private static func webArea(for target: CaptureTarget, window: AXUIElement) -> AXUIElement? {
        let role = "AXWebArea"
        var el = target.textRoot
        for _ in 0..<30 {
            guard let current = el else { break }
            if string(current, kAXRoleAttribute) == role { return current }
            el = attribute(current, kAXParentAttribute)
        }
        var queue = [window], visited = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while !queue.isEmpty, visited < 300, ProcessInfo.processInfo.systemUptime < deadline {
            let node = queue.removeFirst()
            visited += 1
            if string(node, kAXRoleAttribute) == role {
                if frame(node)?.contains(target.center) ?? false { return node }
                continue
            }
            if let children: [AXUIElement] = attribute(node, kAXChildrenAttribute) { queue += children }
        }
        return nil
    }

    struct WindowInfo { var id: CGWindowID; var bounds: CGRect; var pid: pid_t; var owner: String }

    /// Normal on-screen windows, front to back.
    static func windowList() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat],
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0.05 else { return nil }
            let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard rect.width > 40 && rect.height > 40 else { return nil }
            return WindowInfo(id: id, bounds: rect, pid: pid, owner: d[kCGWindowOwnerName as String] as? String ?? "")
        }
    }

    /// Screen frames in top-left coordinates.
    static func screenFrames() -> [CGRect] {
        NSScreen.screens.map { s in
            CGRect(x: s.frame.minX, y: mainHeight - s.frame.maxY, width: s.frame.width, height: s.frame.height)
        }
    }

    static func scale(for region: CGRect) -> CGFloat {
        let c = NSPoint(x: region.midX, y: mainHeight - region.midY)
        return NSScreen.screens.first { $0.frame.contains(c) }?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    struct Hit {
        var frame: CGRect
        var kind: RegionKind
        var scrollBar: AXUIElement?
        var contentHeight: CGFloat?
        var element: AXUIElement?
    }

    /// Walks up from the element under the pointer to the window, describing each element, and
    /// lets `PanePicker` choose: the nearest scroll area or scrolling web column, else the web
    /// area (a browser tab's page, without the tabs and toolbar).
    static func lookUp(at point: CGPoint, pid: pid_t, window: CGRect) -> Hit? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.0)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found) == .success, var el = found else { return nil }
        var elPid: pid_t = 0
        AXUIElementGetPid(el, &elPid)
        guard elPid == pid else { return nil }
        var nodes: [AXNode] = [], elements: [AXUIElement] = []
        for _ in 0..<60 {
            let role = string(el, kAXRoleAttribute) ?? ""
            if role == (kAXWindowRole as String) { break }
            let f = frame(el) ?? .zero
            nodes.append(AXNode(role: role, frame: f, childrenFrame: role == (kAXGroupRole as String) ? childrenExtent(el) : nil))
            elements.append(el)
            guard let parent: AXUIElement = attribute(el, kAXParentAttribute) else { break }
            el = parent
        }
        let pick = PanePicker.pick(path: nodes, window: window, mode: .pane)
        guard let i = pick.index else { return nil }
        let kind: RegionKind = switch pick.kind {
        case .scrollArea: .scrollArea
        case .scrollableWebElement: .webElement
        case .webArea: .webArea
        case .window: .window
        }
        let e = elements[i]
        return Hit(frame: pick.frame, kind: kind, scrollBar: kind == .scrollArea ? settableScrollBar(e) : nil,
                   contentHeight: kind == .scrollArea ? contentHeight(e) : nil, element: e)
    }

    /// The vertical extent of a group's content, from its first and last child.
    static func childrenExtent(_ el: AXUIElement) -> CGRect? {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(el, kAXChildrenAttribute as CFString, &count) == .success, count > 0 else { return nil }
        var first: CFArray?, last: CFArray?
        AXUIElementCopyAttributeValues(el, kAXChildrenAttribute as CFString, 0, 1, &first)
        AXUIElementCopyAttributeValues(el, kAXChildrenAttribute as CFString, count - 1, 1, &last)
        let ends = [(first as? [AXUIElement])?.first, (last as? [AXUIElement])?.first].compactMap { $0 }.compactMap(frame)
        guard let a = ends.first else { return nil }
        return ends.dropFirst().reduce(a) { $0.union($1) }
    }

    /// The scroll area's vertical scroll bar, if its position (AXValue, 0 to 1) can be set.
    static func settableScrollBar(_ area: AXUIElement) -> AXUIElement? {
        guard let bar: AXUIElement = attribute(area, kAXVerticalScrollBarAttribute) else { return nil }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
              let _: NSNumber = attribute(bar, kAXValueAttribute) else { return nil }
        return bar
    }

    /// The height of what the scroll area scrolls (its tallest child that isn't a scroll bar).
    static func contentHeight(_ area: AXUIElement) -> CGFloat? {
        guard let children: [AXUIElement] = attribute(area, kAXChildrenAttribute) else { return nil }
        let heights = children.compactMap { c -> CGFloat? in
            guard string(c, kAXRoleAttribute) != (kAXScrollBarRole as String) else { return nil }
            return frame(c)?.height
        }
        return heights.max()
    }

    static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? { attribute(el, name) }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p: AXValue = attribute(el, kAXPositionAttribute), let s: AXValue = attribute(el, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &origin), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
