import CoreGraphics
import Foundation
import Testing
@testable import TallshotCore

/// A made-up app for the name reader: windows with titles and frames, an optional web page in
/// each, and a focused element. It records every question asked.
final class FakeApp: NameFactsSource {
    struct Window { var frame: CGRect; var title: String?; var url: String? = nil; var pageTitle: String? = nil; var pageDescription: String? = nil }
    enum Element { case window(Int), page(Int), focused }

    var windowList: [Window] = []
    var focusedSubrole: String? = "AXTextArea"
    private(set) var asked: [String] = []

    func focusedElement() -> Element? { asked.append("focused"); return .focused }
    func subrole(of e: Element) -> String? { asked.append("subrole"); if case .focused = e { return focusedSubrole }; return nil }
    func windows() -> [Element] { asked.append("windows"); return windowList.indices.map { .window($0) } }
    func frame(of e: Element) -> CGRect? { asked.append("frame"); if case .window(let i) = e { return windowList[i].frame }; return nil }
    func title(of e: Element) -> String? {
        asked.append("title")
        switch e { case .window(let i): return windowList[i].title; case .page(let i): return windowList[i].pageTitle; case .focused: return nil }
    }
    func webArea(in window: Element) -> Element? {
        asked.append("webArea")
        guard case .window(let i) = window, windowList[i].url != nil || windowList[i].pageTitle != nil else { return nil }
        return .page(i)
    }
    func url(of e: Element) -> String? { asked.append("url"); if case .page(let i) = e { return windowList[i].url }; return nil }
    func pageDescription(of e: Element) -> String? { asked.append("description"); if case .page(let i) = e { return windowList[i].pageDescription }; return nil }
}

@Suite("Reading what a file name may say")
struct NameFactsTests {
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 9, minute: 30))!
    let when = "2026-11-08 at 09.30 - Tallshot"
    let frame = CGRect(x: 100, y: 50, width: 900, height: 700)

    func name(_ app: FakeApp, appName: String, bundleID: String?, isBrowser: Bool, english: Bool = true, own: Bool = false) -> String {
        let kind = CaptureName.kind(bundleID: bundleID, isBrowser: isBrowser)
        let facts = NameFacts.read(from: app, appName: appName, kind: kind, englishLanguage: english, windowFrame: frame, isOwnApp: own)
        return CaptureName.descriptive(facts, date: date)
    }

    func chrome(_ title: String, url: String = "https://www.example.com/a") -> FakeApp {
        let app = FakeApp()
        app.windowList = [.init(frame: frame, title: title, url: url)]
        return app
    }

    @Test func aNormalChromeWindowGetsDomainAndTitle() {
        // The positive control: the reader does find titles and domains when it may use them.
        #expect(name(chrome("Docs - Google Chrome"), appName: "Google Chrome", bundleID: "com.google.Chrome", isBrowser: true)
                == "Google Chrome - example.com - Docs - \(when)")
    }

    @Test func tallshotsOwnWindowAsksNothing() {
        let app = chrome("Tallshot Settings")
        #expect(name(app, appName: "Tallshot", bundleID: "io.github.garoknows.tallshot", isBrowser: false, own: true) == "Tallshot - \(when)")
        #expect(app.asked.isEmpty, "asked Tallshot itself: \(app.asked)")
    }

    @Test func aFocusedPasswordFieldStopsBeforeAnyTitleIsRead() {
        let app = chrome("Sign in - Google Chrome")
        app.focusedSubrole = NameFacts.secureTextFieldSubrole
        #expect(name(app, appName: "Google Chrome", bundleID: "com.google.Chrome", isBrowser: true) == "Google Chrome - \(when)")
        #expect(!app.asked.contains("windows") && !app.asked.contains("title") && !app.asked.contains("url"))
    }

    @Test func anIncognitoWindowFallsBack() {
        for title in ["Secret - Google Chrome (Incognito)", "Secret - Google Chrome - Incognito"] {
            #expect(name(chrome(title), appName: "Google Chrome", bundleID: "com.google.Chrome", isBrowser: true) == "Google Chrome - \(when)")
        }
    }

    @Test func chromeInAnotherLanguageFallsBack() {
        let app = chrome("Seite - Google Chrome")
        #expect(name(app, appName: "Google Chrome", bundleID: "com.google.Chrome", isBrowser: true, english: false) == "Google Chrome - \(when)")
    }

    @Test func chromeAppWindowsFallBack() {
        // An installed web app's window belongs to Chrome, with the app's own title.
        #expect(name(chrome("Inbox - Gmail"), appName: "Google Chrome", bundleID: "com.google.Chrome", isBrowser: true) == "Google Chrome - \(when)")
        // The same window reported under the web app's own name and bundle.
        #expect(name(chrome("Inbox - Gmail"), appName: "Gmail", bundleID: "com.google.Chrome.app.abcdefghijklmnop", isBrowser: true)
                == "Gmail - \(when)")
    }

    @Test func unknownChromeTitleFormatsFallBack() {
        for title in ["Docs", "Docs — Google Chrome", "Google Chrome", "", "Docs - Chrome"] {
            #expect(name(chrome(title), appName: "Google Chrome", bundleID: "com.google.Chrome", isBrowser: true) == "Google Chrome - \(when)")
        }
    }

    @Test func theWindowIsMatchedByItsFrame() {
        let app = FakeApp()
        app.windowList = [.init(frame: CGRect(x: 0, y: 0, width: 400, height: 300), title: "Other note"),
                          .init(frame: frame.offsetBy(dx: 1, dy: -1), title: "Trip plan")]
        #expect(name(app, appName: "Notes", bundleID: "com.apple.Notes", isBrowser: false) == "Notes - Trip plan - \(when)")
    }

    @Test func noMatchingWindowFallsBack() {
        let app = FakeApp()
        app.windowList = [.init(frame: CGRect(x: 0, y: 0, width: 400, height: 300), title: "Other note")]
        #expect(name(app, appName: "Notes", bundleID: "com.apple.Notes", isBrowser: false) == "Notes - \(when)")
    }

    @Test func anElectronAppNamedAfterItselfUsesThePageTitle() {
        let app = FakeApp()
        app.windowList = [.init(frame: frame, title: "Chatter", pageTitle: "Team channel")]
        #expect(name(app, appName: "Chatter", bundleID: "com.example.chatter", isBrowser: false) == "Chatter - Team channel - \(when)")
    }
}
