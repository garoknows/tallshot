/// What the setup window says about Screen Recording. macOS gives a running app the same answer
/// until it restarts, so "reads as off" can mean the switch is off, or that it's on and Tallshot
/// needs to reopen. A brand-new process gets the current answer, which tells the two apart.
public enum ScreenRecordingStep: Equatable, Sendable {
    case allowed
    /// A new process reads it as on, this one as off: reopening will fix it.
    case switchedOnNeedsReopen
    /// Still off everywhere we can see, but the user went to System Settings, and the check of a
    /// new process isn't proof: it may have failed, so offer the button anyway.
    case mayNeedReopen
    case notAllowed

    public init(reads: Bool, freshProcessReads: Bool?, openedSettings: Bool) {
        if reads { self = .allowed }
        else if freshProcessReads == true { self = .switchedOnNeedsReopen }
        else if openedSettings { self = .mayNeedReopen }
        else { self = .notAllowed }
    }

    /// Set when the "Quit & Reopen Tallshot" button should show: the words above it.
    public var reopenNote: String? {
        switch self {
        case .switchedOnNeedsReopen: "The switch is on. Reopen to apply it."
        case .mayNeedReopen: "Switched it on? Reopen to apply it."
        case .allowed, .notAllowed: nil
        }
    }
}
