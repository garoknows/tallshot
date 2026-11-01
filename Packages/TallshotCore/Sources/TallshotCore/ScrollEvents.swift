import CoreGraphics

/// How Tallshot asks an app to scroll. Most apps follow the first; some only follow a plain
/// mouse wheel, so the capture loop falls back down this list if the first step moves nothing.
public enum ScrollMethod: Int, Sendable, CaseIterable, CustomStringConvertible {
    /// Exact positioning through the accessibility tree: set the scroll bar's value. No
    /// animation, no momentum. Only where the app exposes a settable vertical scroll bar.
    case scrollBar
    /// A trackpad-style swipe: precise pixel deltas with a Began / Changed / Ended phase.
    /// Chromium, Electron and WebKit handle precise scrolling by these phases.
    case gesture
    /// A plain mouse-wheel turn in pixel units (not continuous, no phase).
    case wheelPixels
    /// A plain mouse-wheel turn in line units, the oldest kind of scroll event.
    case wheelLines

    public var description: String {
        switch self { case .scrollBar: "accessibility scroll bar"; case .gesture: "trackpad gesture"; case .wheelPixels: "mouse wheel (pixels)"; case .wheelLines: "mouse wheel (lines)" }
    }

    public var next: ScrollMethod? { ScrollMethod(rawValue: rawValue + 1) }
}

/// Builds the scroll-wheel events for one scroll. Building is separate from posting so the
/// tests can check every event: no modifier keys, the right phases, Tallshot's marker.
///
/// Why this matters: the hotkey is Control+Option+Shift+Command+T, and those keys are often
/// still held when the first scroll goes out. An event made from the shared keyboard state
/// carries them along, and Chromium reads Shift+wheel as a sideways scroll and Control+wheel
/// as zoom. So every event comes from a private event source and has its flags cleared.
public enum ScrollEvents {
    /// Marks Tallshot's own events ("TALL") so the cancel watch can tell them from the user's.
    public static let marker: Int64 = 0x5441_4C4C
    /// Largest pixel delta in one event.
    public static let maxPixelChunk = 240
    /// Most lines in one event, and the rough size of a line (Chromium uses 40 points).
    public static let maxLineChunk = 3
    public static let pointsPerLine = 40

    /// A private event source: its modifier state is its own (empty), not the keyboard's.
    public static func privateSource() -> CGEventSource? { CGEventSource(stateID: .privateState) }

    /// The events for one scroll of `points` points at `location`. Positive `points` moves the
    /// content up (scrolls down the page); negative moves back toward the top.
    public static func make(points: Int, at location: CGPoint, inverted: Bool, method: ScrollMethod,
                            source: CGEventSource? = privateSource()) -> [CGEvent] {
        guard points != 0 else { return [] }
        // Negative wheel deltas scroll down.
        let direction: Int32 = (points > 0) != inverted ? -1 : 1
        var events: [CGEvent] = []

        func event(_ units: CGScrollEventUnit, _ delta: Int32) -> CGEvent? {
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)
            else { return nil }
            e.location = location
            e.flags = []   // never carry the hotkey's modifier keys
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)   // no momentum
            return e
        }

        switch method {
        case .scrollBar:
            return []   // not an event: the app sets the scroll bar through Accessibility
        case .gesture:
            var left = abs(points)
            while left > 0 {
                let chunk = min(left, maxPixelChunk)
                left -= chunk
                guard let e = event(.pixel, direction * Int32(chunk)) else { return events }
                e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                let phase: CGScrollPhase = events.isEmpty ? .began : .changed
                e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
                events.append(e)
            }
            // The gesture ends with a zero-delta Ended event, as a trackpad does when the fingers lift.
            if let end = event(.pixel, 0) {
                end.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                end.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.ended.rawValue))
                events.append(end)
            }
        case .wheelPixels:
            var left = abs(points)
            while left > 0 {
                let chunk = min(left, maxPixelChunk)
                left -= chunk
                guard let e = event(.pixel, direction * Int32(chunk)) else { return events }
                e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
                e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
                events.append(e)
            }
        case .wheelLines:
            var left = max(1, Int((Double(abs(points)) / Double(pointsPerLine)).rounded()))
            while left > 0 {
                let chunk = min(left, maxLineChunk)
                left -= chunk
                guard let e = event(.line, direction * Int32(chunk)) else { return events }
                e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
                e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
                events.append(e)
            }
        }
        return events
    }
}

/// Waits for the hotkey's modifier keys to be let go before the first scroll.
public enum ModifierKeys {
    /// Command, Option, Control, Shift and Fn.
    public static let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]

    public static func anyHeld(_ flags: CGEventFlags) -> Bool { !flags.intersection(mask).isEmpty }

    /// Polls `flags` every `pollMs` until no modifier is held, or `timeout` seconds pass.
    /// Returns true if the keys were released, false if it gave up (the capture then continues;
    /// the scroll events carry no modifiers anyway).
    @MainActor
    public static func waitUntilReleased(timeout: Double = 2, pollMs: Int = 20, flags: () -> CGEventFlags,
                                         otherKeyHeld: () -> Bool = { false },
                                         now: () -> Double, sleep: (Int) async -> Void) async -> Bool {
        let start = now()
        while anyHeld(flags()) || otherKeyHeld() {
            if now() - start >= timeout { return false }
            await sleep(pollMs)
        }
        return true
    }
}
