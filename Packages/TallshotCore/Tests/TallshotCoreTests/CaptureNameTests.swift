import Foundation
import Testing
@testable import TallshotCore

@Suite struct CaptureNameTests {
    typealias N = CaptureName
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 14, minute: 5, second: 22))!
    let when = "2026-11-06 at 14.05"

    func chrome(_ title: String?, url: String? = "https://www.example.com/a?b=c") -> N.Facts {
        N.Facts(appName: "Google Chrome", kind: .checkableBrowser, title: title, pageURL: url)
    }

    @Test func ordinaryAppGetsItsTitle() {
        let f = N.Facts(appName: "Notes", kind: .ordinary, title: "Trip plan")
        #expect(N.descriptive(f, date: date) == "Notes - Trip plan - \(when)")
    }
    @Test func appNameIsNotRepeated() {
        for title in ["Trip plan - Notes", "Notes - Trip plan", "Trip plan — Notes", "Trip plan | Notes"] {
            #expect(N.descriptive(N.Facts(appName: "Notes", kind: .ordinary, title: title), date: date) == "Notes - Trip plan - \(when)")
        }
        #expect(N.descriptive(N.Facts(appName: "Notes", kind: .ordinary, title: "Notes"), date: date) == "Notes - \(when)")
    }
    @Test func chromeGetsDomainThenTitle() {
        #expect(N.descriptive(chrome("Chat test - Google Chrome"), date: date) == "Google Chrome - example.com - Chat test - \(when)")
    }
    @Test func ordinaryAppNeverGetsADomain() {
        let f = N.Facts(appName: "Notes", kind: .ordinary, title: "Trip plan", pageURL: "https://example.com/")
        #expect(N.descriptive(f, date: date) == "Notes - Trip plan - \(when)")
    }

    // Private windows and password fields.
    @Test func incognitoWindowGetsNoTitleOrDomain() {
        for title in ["Secret page - Google Chrome (Incognito)", "Secret page - Google Chrome - Incognito", "Secret (INCOGNITO) - Google Chrome"] {
            #expect(N.descriptive(chrome(title), date: date) == "Google Chrome - \(when)")
        }
    }
    @Test func chromeTitleInAnUnexpectedFormIsNotTrusted() {
        #expect(N.descriptive(chrome("Secret page"), date: date) == "Google Chrome - \(when)")
    }
    @Test func chromeInAnotherLanguageIsNotTrusted() {
        var f = chrome("Page - Google Chrome")
        f.englishLanguage = false
        #expect(N.descriptive(f, date: date) == "Google Chrome - \(when)")
    }
    @Test func browsersThatCannotBeCheckedGetOnlyAppAndDate() {
        let f = N.Facts(appName: "Arc", kind: .uncheckableBrowser, title: "Secret page", pageURL: "https://example.com/")
        #expect(N.descriptive(f, date: date) == "Arc - \(when)")
    }
    @Test func onlyKnownBrowsersAreCheckable() {
        #expect(N.kind(bundleID: "com.google.Chrome", isBrowser: true) == .checkableBrowser)
        #expect(N.kind(bundleID: "company.thebrowser.Browser", isBrowser: true) == .uncheckableBrowser)
        #expect(N.kind(bundleID: "com.apple.Safari", isBrowser: true) == .uncheckableBrowser)
        #expect(N.kind(bundleID: "com.example.unknown", isBrowser: true) == .uncheckableBrowser)
        #expect(N.kind(bundleID: "com.apple.Notes", isBrowser: false) == .ordinary)
    }
    @Test func passwordFieldInFocusRemovesTitleAndDomain() {
        var f = chrome("Sign in - Google Chrome")
        f.passwordFieldFocused = true
        #expect(N.descriptive(f, date: date) == "Google Chrome - \(when)")
        let notes = N.Facts(appName: "Notes", kind: .ordinary, title: "Vault", passwordFieldFocused: true)
        #expect(N.descriptive(notes, date: date) == "Notes - \(when)")
    }
    @Test func privateWordsInAnyAppRemoveTheTitle() {
        for title in ["Page - Private Browsing", "Page [InPrivate]", "Page (Incognito)"] {
            #expect(N.descriptive(N.Facts(appName: "Other", kind: .ordinary, title: title), date: date) == "Other - \(when)")
        }
    }

    // Domains.
    @Test func domainIsOnlyTheHost() {
        #expect(N.domain(from: "https://user:hunter2@www.Example.com:8443/private/path?token=abc#x") == "example.com")
        #expect(N.domain(from: "http://docs.example.com") == "docs.example.com")
    }
    @Test func nonWebAddressesHaveNoDomain() {
        for address in ["file:///tmp/a.html", "about:blank", "chrome://settings", "", "not a url"] {
            #expect(N.domain(from: address) == nil)
        }
        #expect(N.domain(from: nil) == nil)
    }

    // Safe, short names.
    @Test func refusedCharactersAreRemoved() {
        #expect(N.clean("a/b\\c:d*e?f\"g<h>i|j") == "a b c d e f g h i j")
        #expect(N.clean("line one\nline\ttwo") == "line one line two")
        #expect(N.clean("...hidden file...") == "hidden file")
        #expect(N.clean("") == "")
    }
    @Test func invisibleAndDirectionCharactersAreRemoved() {
        #expect(N.clean("abc\u{202E}gnp.exe") == "abcgnp.exe")
        #expect(N.clean("a\u{200B}b\u{FEFF}c") == "abc")
    }
    @Test func aTitleOfOnlyRefusedCharactersIsLeftOut() {
        #expect(N.descriptive(N.Facts(appName: "Notes", kind: .ordinary, title: "///..."), date: date) == "Notes - \(when)")
    }
    @Test func longTitlesAreTrimmedToAboutSixtyCharacters() throws {
        let long = String(repeating: "word ", count: 40)
        let name = N.descriptive(N.Facts(appName: "Notes", kind: .ordinary, title: long), date: date)
        #expect(name.hasPrefix("Notes - word word"))
        #expect(name.hasSuffix("… - \(when)"))
        #expect(name.count <= "Notes - ".count + 60 + " - \(when)".count)
    }
    @Test func wideCharactersStayWithinTheFileNameLimit() {
        let emoji = String(repeating: "🦊", count: 500)
        let name = N.descriptive(N.Facts(appName: emoji, kind: .checkableBrowser, title: emoji + " - " + emoji,
                                         pageURL: "https://" + String(repeating: "a", count: 300) + ".example.com/"), date: date)
        #expect(name.utf8.count <= 220)
        #expect(name.hasSuffix(when))
    }
    @Test func aMissingAppNameStillGivesAName() {
        #expect(N.descriptive(N.Facts(appName: "", kind: .ordinary), date: date) == "Tallshot - \(when)")
    }
    @Test func plainNameIsTheOriginalDateName() {
        #expect(N.plain(date: date) == "Tallshot 2026-11-06 at 14.05.22")
    }
}
