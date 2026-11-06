import CoreGraphics

/// What to capture: just the pane under the pointer, or the whole window.
public enum CaptureMode: String, CaseIterable, Sendable {
    case pane
    case window

    public var title: String { self == .pane ? "Pane under the pointer" : "Whole window" }
}

/// One element on the way up from the element under the pointer to the window, as the
/// accessibility tree describes it. Plain data, so the choice can be tested without an app.
public struct AXNode: Equatable, Sendable {
    public var role: String
    public var frame: CGRect
    /// The combined frame of its children, when known (taller than `frame` means its content
    /// is taller than the box: it scrolls).
    public var childrenFrame: CGRect?
    public init(role: String, frame: CGRect, childrenFrame: CGRect? = nil) {
        self.role = role; self.frame = frame; self.childrenFrame = childrenFrame
    }

    /// A web element whose content is taller than its box: an inner scrolling column that
    /// Chromium doesn't report as a scroll area.
    public var looksScrollable: Bool {
        guard let c = childrenFrame, frame.height >= 60, frame.width >= 60 else { return false }
        return c.height > frame.height * 1.15 + 8 && c.minX >= frame.minX - 4 && c.maxX <= frame.maxX + 4
    }
}

public enum PickKind: String, Sendable {
    case scrollArea, scrollableWebElement, webArea, window
}

public struct PanePick: Equatable, Sendable {
    public var frame: CGRect
    public var kind: PickKind
    /// Index in the path of the element picked (nil for the window).
    public var index: Int?
}

/// Picks the capture region from the path under the pointer (`path[0]` is the element under
/// the pointer, the last is closest to the window).
///
/// Pane mode: the nearest scroll area or, inside a web page, the nearest element whose content is
/// taller than its box (a scrolling column Chromium exposes as a plain group); else the web area
/// (the browser tab's page, without tabs or toolbar); else the window (cropped later to what moved).
/// Whole-window mode: the window.
public enum PanePicker {
    public static let minSize: CGFloat = 60

    /// Electron apps can report one scroll area for the entire window, sidebar included. Such a
    /// pick isn't really a pane, so the finished capture is cropped to the columns that moved.
    public static func scrollAreaFillsWindow(_ area: CGRect, window: CGRect) -> Bool {
        let f = area.intersection(window)
        return f.width >= window.width * 0.9 && f.height >= window.height * 0.9
    }

    public static func pick(path: [AXNode], window: CGRect, mode: CaptureMode) -> PanePick {
        let fallback = PanePick(frame: window, kind: .window, index: nil)
        guard mode == .pane else { return fallback }
        func usable(_ n: AXNode) -> CGRect? {
            let f = n.frame.intersection(window)
            return f.width >= minSize && f.height >= minSize ? f : nil
        }
        // Walking up from the pointer, the nearest thing that scrolls: a scroll area, or (inside
        // the web page) an element whose content is taller than its box. Browsers put a scroll
        // area for the whole page above the web area, so a nearer inner column must win over it.
        let web = path.firstIndex { $0.role == "AXWebArea" && usable($0) != nil }
        for (i, n) in path.enumerated() where usable(n) != nil {
            if n.role == "AXScrollArea" { return PanePick(frame: usable(n)!, kind: .scrollArea, index: i) }
            if (web.map { i < $0 } ?? true) && n.role != "AXWebArea" && n.looksScrollable {
                return PanePick(frame: usable(n)!, kind: .scrollableWebElement, index: i)
            }
        }
        if let w = web { return PanePick(frame: usable(path[w])!, kind: .webArea, index: w) }
        return fallback
    }
}

/// Which window a capture is for, from the on-screen windows listed front to back.
public enum WindowChoice {
    /// With a pointer (the hotkey): the window under it. Without one (the menu, whose own items
    /// sit over whatever is behind them), or over no window: the front app's front window, then
    /// the frontmost window of any other app. Never Tallshot's own window unless pointed at.
    public static func index(frames: [CGRect], owners: [Int32], pointer: CGPoint?, front: Int32?, own: Int32) -> Int? {
        if let pointer, let under = frames.firstIndex(where: { $0.contains(pointer) }) { return under }
        if let front, front != own, let i = owners.firstIndex(of: front) { return i }
        return owners.firstIndex { $0 != own }
    }
}

/// Known hotkey clashes, so Settings can warn right under the hotkey field.
public enum HotkeyConflicts {
    /// Carbon modifier bits (what RegisterEventHotKey uses).
    public static let cmd: UInt32 = 1 << 8, shift: UInt32 = 1 << 9, option: UInt32 = 1 << 11, control: UInt32 = 1 << 12
    public static let hyper: UInt32 = cmd | shift | option | control

    /// Virtual key codes for the letters that matter here.
    public static let keyC: UInt32 = 8, keyV: UInt32 = 9, keyF: UInt32 = 3, keyX: UInt32 = 7, keySpace: UInt32 = 49
    public static let key3: UInt32 = 20, key4: UInt32 = 21, key5: UInt32 = 23, key6: UInt32 = 22

    struct Known {
        var app: String
        var bundleID: String?
        var keyCode: UInt32
        var modifiers: UInt32
    }

    /// Shortcuts other apps commonly use. Raycast setups often put clipboard, window and other
    /// commands on Control+Option+Shift+Command (the "Hyper" key) with C, V, F and X.
    static let known: [Known] = [
        Known(app: "macOS (screenshots)", bundleID: nil, keyCode: key3, modifiers: cmd | shift),
        Known(app: "macOS (screenshots)", bundleID: nil, keyCode: key4, modifiers: cmd | shift),
        Known(app: "macOS (screenshots)", bundleID: nil, keyCode: key5, modifiers: cmd | shift),
        Known(app: "macOS (screenshots)", bundleID: nil, keyCode: key6, modifiers: cmd | shift),
        Known(app: "Spotlight", bundleID: nil, keyCode: keySpace, modifiers: cmd),
        Known(app: "Raycast", bundleID: "com.raycast.macos", keyCode: keySpace, modifiers: option),
        Known(app: "Raycast", bundleID: "com.raycast.macos", keyCode: keyC, modifiers: hyper),
        Known(app: "Raycast", bundleID: "com.raycast.macos", keyCode: keyV, modifiers: hyper),
        Known(app: "Raycast", bundleID: "com.raycast.macos", keyCode: keyF, modifiers: hyper),
        Known(app: "Raycast", bundleID: "com.raycast.macos", keyCode: keyX, modifiers: hyper),
        Known(app: "Alfred", bundleID: "com.runningwithcrayons.Alfred", keyCode: keySpace, modifiers: option),
        Known(app: "1Password", bundleID: "com.1password.1password", keyCode: keySpace, modifiers: cmd | shift),
    ]

    /// A warning for a hotkey, or nil. `registered` is whether macOS accepted it; `systemTaken`
    /// whether it matches an enabled macOS keyboard shortcut; `running` the apps now open.
    public static func warning(keyCode: UInt32, modifiers: UInt32, registered: Bool, systemTaken: Bool,
                               running: Set<String>) -> String? {
        if !registered { return "macOS refused this hotkey (another app has it). Pick a different one." }
        if systemTaken { return "macOS already uses this for a keyboard shortcut (System Settings → Keyboard → Keyboard Shortcuts), so it may not reach Tallshot." }
        for k in known where k.keyCode == keyCode && k.modifiers == modifiers {
            if let id = k.bundleID {
                if running.contains(id) { return "\(k.app) is running and may use this hotkey, so it may not reach Tallshot." }
            } else {
                return "\(k.app) uses this hotkey, so it may not reach Tallshot."
            }
        }
        return nil
    }
}
