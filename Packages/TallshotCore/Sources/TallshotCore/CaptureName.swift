import Foundation

/// The name a capture's files share: what's in them, when it was taken, then "Tallshot". For example
/// "Notes - Trip plan - 2026-11-06 at 14.05 - Tallshot" or
/// "Arc - example.com - Docs - 2026-11-06 at 14.05 - Tallshot".
///
/// A title or domain is left out when a password field has the keyboard or the title says the
/// window is private (Chrome's Incognito, for example).
public enum CaptureName {
    public enum AppKind: Sendable {
        /// Not a web browser: the title only, no domain.
        case ordinary
        /// A web browser: the page's domain and title.
        case browser
        /// Chrome, whose window title says "(Incognito)" for a private window. Its title is used
        /// only when it has the form a normal window's has.
        case chrome
    }

    public static let chromeIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
    ]

    /// Chrome itself, and the web apps installed from it ("com.google.Chrome.app.…"), whose
    /// windows are Chrome windows with the web app's title.
    public static func kind(bundleID: String?, isBrowser: Bool) -> AppKind {
        if let bundleID, chromeIDs.contains(bundleID) || bundleID.hasPrefix("com.google.Chrome.") { return .chrome }
        return isBrowser ? .browser : .ordinary
    }

    public struct Facts: Sendable {
        public var appName: String
        public var kind: AppKind
        public var title: String?
        public var pageURL: String?
        /// A password field has the keyboard. Only the field's type is known, never its contents.
        public var passwordFieldFocused: Bool
        /// Chrome's Incognito label is only recognized in English.
        public var englishLanguage: Bool

        public init(appName: String, kind: AppKind, title: String? = nil, pageURL: String? = nil,
                    passwordFieldFocused: Bool = false, englishLanguage: Bool = true) {
            self.appName = appName
            self.kind = kind
            self.title = title
            self.pageURL = pageURL
            self.passwordFieldFocused = passwordFieldFocused
            self.englishLanguage = englishLanguage
        }
    }

    /// Every name ends with this, so Tallshot's files are easy to find.
    public static let ending = " - Tallshot"

    /// "2026-10-31 at 14.05.22 - Tallshot"
    public static func plain(date: Date) -> String {
        format(date, "yyyy-MM-dd 'at' HH.mm.ss") + ending
    }

    /// "App - domain - title - 2026-10-31 at 14.05 - Tallshot", leaving out whatever can't be used.
    public static func descriptive(_ facts: Facts, date: Date) -> String {
        let when = format(date, "yyyy-MM-dd 'at' HH.mm")
        let app = trim(clean(facts.appName), characters: 30, bytes: 60)
        let shown = usable(facts)
        let domain = shown.domain.map { trim($0, characters: 60, bytes: 60) } ?? ""
        let start = [app, domain].filter { !$0.isEmpty }
        let others = (start + [when]).joined(separator: separator).utf8.count + separator.utf8.count + ending.utf8.count
        let title = shown.title.map { trim(clean($0), characters: maxTitleCharacters, bytes: max(0, maxBytes - others)) } ?? ""
        return (start + [title, when]).filter { !$0.isEmpty }.joined(separator: separator) + ending
    }

    /// Just the host of a web address, without "www.". Never the path, query or any login in it.
    public static func domain(from address: String?) -> String? {
        guard let address, let parts = URLComponents(string: address),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let cleaned = clean(host)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Makes text safe in a file name: no characters file systems refuse, no invisible or
    /// direction-changing characters, no leading dot that would hide the file.
    public static func clean(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            if refused.contains(scalar) { return " " }
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return " "
            case .format: return "\u{0}"
            default: return Character(scalar)
            }
        }
        let joined = String(scalars.filter { $0 != "\u{0}" })
        let words = joined.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(words.drop(while: { $0 == "." || $0 == " " })).strippingTrailing { $0 == "." || $0 == " " }
    }

    // MARK: - Private

    private static let separator = " - "
    private static let maxTitleCharacters = 60
    /// File names can be 255 bytes. This leaves room for " diagnostics 99" and ".docx".
    private static let maxBytes = 220
    private static let refused = CharacterSet(charactersIn: "/\\:*?\"<>|")
    private static let privateMarkers = ["incognito", "private browsing", "inprivate"]
    /// Browsers whose window title ends with a longer name than the app's.
    private static let longNames = ["Firefox": "Mozilla Firefox"]

    private static func usable(_ facts: Facts) -> (title: String?, domain: String?) {
        guard !facts.passwordFieldFocused, let title = facts.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return (nil, nil) }
        let lower = title.lowercased()
        if privateMarkers.contains(where: { lower.contains($0) }) { return (nil, nil) }
        switch facts.kind {
        case .ordinary:
            return (withoutAppName(title, app: facts.appName), nil)
        case .browser:
            var t: String? = title
            if let long = longNames[facts.appName] { t = t.flatMap { withoutAppName($0, app: long) } }
            return (t.flatMap { withoutAppName($0, app: facts.appName) }, domain(from: facts.pageURL))
        case .chrome:
            // A normal window's title ends with the browser's name ("Google Chrome", "Google Chrome
            // Beta"). Anything else might be a private window whose label looks different, or an
            // installed web app's window, so it isn't used.
            guard facts.englishLanguage, facts.appName.hasPrefix("Google Chrome"),
                  title.hasSuffix(separator + facts.appName) else { return (nil, nil) }
            return (withoutAppName(title, app: facts.appName), domain(from: facts.pageURL))
        }
    }

    private static func withoutAppName(_ title: String, app: String) -> String? {
        var t = title
        for mark in [" - ", " – ", " — ", " | "] {
            if t.hasSuffix(mark + app) { t.removeLast((mark + app).count) }
            if t.hasPrefix(app + mark) { t.removeFirst((app + mark).count) }
        }
        return t.isEmpty || t == app ? nil : t
    }

    /// Shortens at a space when one is near the end, and marks the cut with "…".
    private static func trim(_ text: String, characters: Int, bytes: Int) -> String {
        guard text.count > characters || text.utf8.count > bytes else { return text }
        var cut = String(text.prefix(max(0, characters - 1)))
        while cut.utf8.count + 3 > bytes, !cut.isEmpty { cut.removeLast() }
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > cut.count * 2 / 3 {
            cut = String(cut[..<space])
        }
        cut = cut.strippingTrailing { $0 == " " || $0 == "-" || $0 == "." }
        return cut.isEmpty ? "" : cut + "…"
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

private extension String {
    func strippingTrailing(_ drop: (Character) -> Bool) -> String {
        var s = self
        while let last = s.last, drop(last) { s.removeLast() }
        return s
    }
}
