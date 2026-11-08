import CoreGraphics

/// What reading a capture's name needs to ask the target app through Accessibility. The app
/// answers with real accessibility calls; tests answer with made-up windows.
public protocol NameFactsSource {
    associatedtype Element
    /// The element that has the keyboard in the app.
    func focusedElement() -> Element?
    func subrole(of element: Element) -> String?
    func windows() -> [Element]
    func frame(of element: Element) -> CGRect?
    func title(of element: Element) -> String?
    /// The web page holding the captured area, in `window` (nil when there isn't one).
    func webArea(in window: Element) -> Element?
    func url(of element: Element) -> String?
    func pageDescription(of element: Element) -> String?
}

/// Decides what a capture's file name may say, from what the app reports.
public enum NameFacts {
    /// The subrole of a password field (Accessibility's `kAXSecureTextFieldSubrole`).
    public static let secureTextFieldSubrole = "AXSecureTextField"

    /// The facts for `CaptureName.descriptive`. Only a focused field's type is checked, never what
    /// is typed in it. With `isOwnApp` (the capture is of Tallshot's own window) nothing is asked
    /// at all: Tallshot would be waiting on itself, so the name is just the app's.
    public static func read<S: NameFactsSource>(from source: S, appName: String, kind: CaptureName.AppKind,
                                                englishLanguage: Bool, windowFrame: CGRect, isOwnApp: Bool) -> CaptureName.Facts {
        var facts = CaptureName.Facts(appName: appName, kind: kind, englishLanguage: englishLanguage)
        guard !isOwnApp else { return facts }
        if let focused = source.focusedElement(), source.subrole(of: focused) == secureTextFieldSubrole {
            facts.passwordFieldFocused = true
            return facts
        }
        guard let window = source.windows().first(where: { source.frame(of: $0).map { sameFrame($0, windowFrame) } ?? false }) else {
            return facts
        }
        let title = source.title(of: window)
        facts.title = title
        switch kind {
        case .browser, .chrome:
            if let page = source.webArea(in: window) { facts.pageURL = source.url(of: page) }
        case .ordinary:
            // Many Electron apps name the window after themselves and the page after what's open.
            if title?.isEmpty ?? true || title == appName, let page = source.webArea(in: window) {
                let named = [source.title(of: page), source.pageDescription(of: page)].compactMap { $0 }
                facts.title = named.first { !$0.isEmpty } ?? title
            }
        }
        return facts
    }

    static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
}
