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
    /// Where to send scroll events. They go to whatever window is on top at that point, so:
    /// `preferred` if the target window is on top there; else the spot the user pointed at, if
    /// it's in the region and the target is on top there; else `preferred` anyway.
    /// `frames` and `ids` are the on-screen windows, front to back.
    public static func scrollPoint(preferred: CGPoint, probe: CGPoint, region: CGRect, frames: [CGRect], ids: [UInt32],
                                   target: UInt32) -> CGPoint {
        func onTop(_ p: CGPoint) -> Bool { frames.firstIndex { $0.contains(p) }.map { ids[$0] == target } ?? true }
        if onTop(preferred) { return preferred }
        if region.contains(probe), onTop(probe) { return probe }
        return preferred
    }

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

    /// Screenshot apps that register global hotkeys of their own.
    public static let screenshotApps: [(name: String, bundleID: String)] = [
        ("Shottr", "cc.ffitch.shottr"), ("CleanShot X", "pl.maketheweb.cleanshotx"),
    ]

    /// macOS refused the hotkey because another app registered it first. macOS doesn't say which
    /// app, so a running screenshot app is named as the likely one.
    public static func refusedMessage(display: String = "this hotkey", running: Set<String>) -> String {
        let shots = screenshotApps.filter { running.contains($0.bundleID) }.map(\.name)
        let likely = shots.isEmpty ? "" : " \(shots.joined(separator: " or ")) is running and is the likely one: check its shortcuts."
        return "macOS refused \(display) (another app has it), so it wasn't kept.\(likely) Pick a different one."
    }

    /// One hotkey's key and modifiers.
    public struct Keys: Equatable, Sendable {
        public var keyCode: UInt32, modifiers: UInt32
        public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    }

    /// Another of Tallshot's hotkey slots that already has the same keys as `slot` (the lowest
    /// numbered one), or nil.
    public static func sameKeys(as slot: UInt32, in keys: [UInt32: Keys]) -> UInt32? {
        guard let mine = keys[slot] else { return nil }
        return keys.filter { $0.key != slot && $0.value == mine }.keys.min()
    }

    /// Virtual key codes for the letters that matter here.
    public static let keyC: UInt32 = 8, keyV: UInt32 = 9, keyF: UInt32 = 3, keyX: UInt32 = 7, keySpace: UInt32 = 49
    public static let key3: UInt32 = 20, key4: UInt32 = 21, key5: UInt32 = 23, key6: UInt32 = 22

    public static func warning(keyCode: UInt32, modifiers: UInt32, registered: Bool, systemTaken: Bool,
                               running: Set<String>) -> String? {
        // Only with evidence of a clash: macOS refused the hotkey, or macOS's own keyboard
        // shortcut settings use the same keys. Guessing from which apps are running gave false
        // warnings (Raycast was named for keys it didn't use).
        if !registered { return refusedMessage(running: running) }
        if systemTaken { return "macOS already uses this for a keyboard shortcut (System Settings → Keyboard → Keyboard Shortcuts), so it may not reach Tallshot." }
        return nil
    }
}

/// Settings → Test Hotkey: waits for the user to press one of Tallshot's hotkeys, and says whether
/// it reached Tallshot. While it waits, a press is only recorded, nothing is captured.
public struct HotkeyTest: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case waiting(since: Double)
        /// The hotkey in this slot (1 capture, 2 from top, 3 as image) reached Tallshot.
        case received(slot: UInt32)
        case timedOut
    }

    public static let timeout = 10.0
    public private(set) var state: State = .idle
    public init() {}

    public var isWaiting: Bool { if case .waiting = state { return true } else { return false } }

    public mutating func start(now: Double) { state = .waiting(since: now) }

    /// A hotkey was pressed. Returns true if the test took it (so no capture should start).
    public mutating func pressed(slot: UInt32, now: Double) -> Bool {
        guard case .waiting(let since) = state else { return false }
        guard now - since <= Self.timeout else { state = .timedOut; return false }
        state = .received(slot: slot)
        return true
    }

    public mutating func tick(now: Double) {
        if case .waiting(let since) = state, now - since > Self.timeout { state = .timedOut }
    }

    public mutating func cancel() { state = .idle }

    /// What Settings shows. `display` names a slot's keys.
    public func message(display: (UInt32) -> String?) -> String? {
        switch state {
        case .idle: nil
        case .waiting: "Press one of Tallshot's hotkeys now…"
        case .received(let slot): "\(display(slot) ?? "The hotkey") reached Tallshot. It works."
        case .timedOut: "No Tallshot hotkey arrived within \(Int(Self.timeout)) seconds. Another app may be taking it, or it isn't set."
        }
    }
}

/// How one hotkey row in Settings looks. Every row works the same way: it shows the keys, or
/// "Click to record" when there are none; Clear when keys are set; and, for a row with a default
/// (the main Capture hotkey), Reset to Default when the keys differ from it. Hidden buttons keep
/// their space, so the layout never shifts.
public struct HotkeyField: Equatable, Sendable {
    public static let placeholder = "Click to record"
    public static let recordingTitle = "Press keys…"

    public var title: String
    public var showsClear: Bool
    /// nil when the row has no default.
    public var showsReset: Bool?

    /// `display`: the keys, or nil for none. `hasDefault`: the row has a default hotkey;
    /// `isDefault`: its keys are that default.
    public static func state(display: String?, recording: Bool, hasDefault: Bool, isDefault: Bool) -> HotkeyField {
        HotkeyField(title: recording ? recordingTitle : (display ?? placeholder),
                    showsClear: display != nil && !recording,
                    showsReset: hasDefault ? (!isDefault && !recording) : nil)
    }
}

extension HotkeyConflicts {
    /// Another slot that already has `keys` (the lowest numbered one), ignoring `slot` itself.
    public static func slot(using keys: Keys, except slot: UInt32, in all: [UInt32: Keys]) -> UInt32? {
        all.filter { $0.key != slot && $0.value == keys }.keys.min()
    }
}
