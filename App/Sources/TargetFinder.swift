import AppKit
import ApplicationServices

/// What to capture: one window, and the scrolling area inside it.
struct CaptureTarget {
    /// The capture region in global screen points, origin at the top-left of the main display.
    var region: CGRect
    var windowID: CGWindowID
    var windowFrame: CGRect
    var pid: pid_t
    /// True when the region is a real scrolling area; false for the front-window fallback.
    var isScrollArea: Bool
    var appName: String

    var center: CGPoint { CGPoint(x: region.midX, y: region.midY) }
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

    /// The target under `point`, or the front window's content area if nothing there scrolls.
    static func find(at point: CGPoint, onlyPID: pid_t? = nil) -> CaptureTarget? {
        let windows = windowList()
        let own = ProcessInfo.processInfo.processIdentifier
        let under = windows.first { $0.bounds.contains(point) && (onlyPID == nil || $0.pid == onlyPID) }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let window = under ?? windows.first(where: { $0.pid == front && $0.pid != own }) else { return nil }

        var region = window.bounds
        var isScroll = false
        // From the menu the pointer is on the menu bar: look at the middle of the front window instead.
        let probe = window.bounds.contains(point) ? point : CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        if let area = scrollArea(at: probe, pid: window.pid) {
            let clipped = area.intersection(window.bounds)
            if clipped.width >= 60 && clipped.height >= 60 { region = clipped; isScroll = true }
        }
        // Keep to the part that is on a screen, so the pointer can sit in the middle of it.
        if let screen = screenFrames().first(where: { $0.contains(CGPoint(x: region.midX, y: region.midY)) }) {
            region = region.intersection(screen)
        }
        region = region.integral
        guard region.width >= 20 && region.height >= 20 else { return nil }
        return CaptureTarget(region: region, windowID: window.id, windowFrame: window.bounds, pid: window.pid,
                             isScrollArea: isScroll, appName: window.owner)
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

    /// Walks up from the element under the pointer to the nearest scroll area and returns its frame.
    static func scrollArea(at point: CGPoint, pid: pid_t) -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.0)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, var el = hit else { return nil }
        var elPid: pid_t = 0
        AXUIElementGetPid(el, &elPid)
        guard elPid == pid else { return nil }
        for _ in 0..<40 {
            if string(el, kAXRoleAttribute) == (kAXScrollAreaRole as String), let f = frame(el), f.width >= 60, f.height >= 60 {
                return f
            }
            guard let parent: AXUIElement = attribute(el, kAXParentAttribute) else { return nil }
            el = parent
        }
        return nil
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
