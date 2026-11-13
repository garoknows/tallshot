import AppKit
import ApplicationServices
import TallshotCore

/// Reads an app's whole accessibility tree for one window, for Check This App and for a chat
/// app's text capture. Only reads: no pictures, no scrolling, no events, no changes, no files.
/// Each element's attributes come back in one request, so a long conversation reads quickly.
/// The counting and the walk run off the main thread, so Tallshot's menu and pop-ups keep working.
enum TreeWalker {
    nonisolated static let attributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute, kAXValueAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute, "AXDOMClassList", kAXURLAttribute,
    ]

    struct Walk: Sendable {
        var tree: ProbeTree
        /// Stopped at the element or time limit: the tree is incomplete.
        var cutShort: Bool
        /// Elements that didn't answer (even when asked again): what's inside them is missing.
        var failed: Int
        var complete: Bool { !cutShort && failed == 0 }
    }

    /// An accessibility element handed to a background task. AXUIElement can be used from any
    /// thread; only the type isn't marked so.
    struct Element: @unchecked Sendable { let ax: AXUIElement }

    /// The app's window at `frame` (top-left screen points), else its focused window.
    @MainActor static func window(pid: pid_t, frame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        let windows: [AXUIElement] = TargetFinder.attribute(app, kAXWindowsAttribute) ?? []
        if let w = windows.first(where: { TargetFinder.frame($0).map { abs($0.minX - frame.minX) < 2 && abs($0.minY - frame.minY) < 2 } ?? false }) {
            return w
        }
        return TargetFinder.attribute(app, kAXFocusedWindowAttribute)
    }

    /// Waits (up to `seconds`) until the tree stops growing: an Electron app builds it after its
    /// accessibility switch is turned on. A tree too big to count quickly is taken as built.
    /// Answers how long that took, in milliseconds.
    @MainActor static func settle(_ root: AXUIElement, seconds: Double) async -> Int {
        let start = ProcessInfo.processInfo.systemUptime
        let element = Element(ax: root)
        var counts: [Int] = []
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            let (n, finished) = await Task.detached { count(element.ax) }.value
            counts.append(n)
            if !finished || TreeSettling.settled(counts: counts) { break }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    /// How many elements the tree has now (a quick walk, at most 2 seconds), and whether the
    /// count finished.
    nonisolated static func count(_ root: AXUIElement, limit: Int = 80_000) -> (Int, Bool) {
        var queue = [root], i = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while i < queue.count, queue.count < limit, ProcessInfo.processInfo.systemUptime < deadline {
            AXUIElementSetMessagingTimeout(queue[i], 0.5)
            queue += (TargetFinder.attribute(queue[i], kAXChildrenAttribute) as [AXUIElement]?) ?? []
            i += 1
        }
        return (queue.count, i >= queue.count)
    }

    /// The whole tree under `root`, read on a background thread.
    @MainActor static func walk(_ root: AXUIElement, maxNodes: Int = 80_000, seconds: Double = 15) async -> Walk {
        let element = Element(ax: root)
        return await Task.detached { walkNow(element.ax, maxNodes: maxNodes, seconds: seconds) }.value
    }

    /// The whole tree under `root`, parents before children, children in order.
    nonisolated static func walkNow(_ root: AXUIElement, maxNodes: Int, seconds: Double) -> Walk {
        var nodes: [ProbeNode] = []
        var queue: [(AXUIElement, Int?)] = [(root, nil)], i = 0, failed = 0
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        let names = attributes as CFArray
        while i < queue.count, nodes.count < maxNodes, ProcessInfo.processInfo.systemUptime < deadline {
            let (el, parent) = queue[i]; i += 1
            AXUIElementSetMessagingTimeout(el, 0.5)
            // Asked twice: a busy app can miss one request.
            var values: [AnyObject?]?
            for _ in 0..<2 where values == nil {
                var raw: CFArray?
                if AXUIElementCopyMultipleAttributeValues(el, names, [], &raw) == .success, let list = raw as [AnyObject]?, list.count == attributes.count {
                    values = list.map(clean)
                }
            }
            guard let values else {
                failed += 1
                nodes.append(ProbeNode(role: "", frame: nil, parent: parent))
                continue
            }
            func string(_ k: Int) -> String? { values[k] as? String }
            let role = string(0) ?? ""
            var frame: CGRect?
            if let p = values[7], let s = values[8], CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() {
                var point = CGPoint.zero, size = CGSize.zero
                if AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) {
                    frame = CGRect(origin: point, size: size)
                }
            }
            let text = role == "AXStaticText" ? string(3) : nil
            let level = role == "AXHeading" ? (values[3] as? NSNumber)?.intValue : nil
            let label = [string(5), string(4)].compactMap { $0 }.first { !$0.isEmpty }
            let url = (values[10] as? URL)?.absoluteString ?? (values[10] as? String)
            let index = nodes.count
            nodes.append(ProbeNode(role: role, frame: frame, classes: (values[9] as? [String]) ?? [], parent: parent,
                                   text: text, label: label, url: url, level: level,
                                   subrole: string(1), roleDescription: string(2)))
            for k in (values[6] as? [AXUIElement]) ?? [] { queue.append((k, index)) }
        }
        return Walk(tree: ProbeTree(nodes), cutShort: i < queue.count, failed: failed)
    }

    /// An attribute the element doesn't have comes back as an error value: nil.
    nonisolated private static func clean(_ v: AnyObject) -> AnyObject? {
        if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
        return v
    }
}
