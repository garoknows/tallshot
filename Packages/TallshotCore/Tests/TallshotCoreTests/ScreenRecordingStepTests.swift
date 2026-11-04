import Testing
@testable import TallshotCore

@Suite struct ScreenRecordingStepTests {
    @Test func readingOnIsAllowedWhateverElseIsTrue() {
        #expect(ScreenRecordingStep(reads: true, freshProcessReads: false, openedSettings: true) == .allowed)
        #expect(ScreenRecordingStep.allowed.reopenNote == nil)
    }

    @Test func aNewProcessReadingOnMeansReopenEvenWithoutOpeningSettings() {
        let s = ScreenRecordingStep(reads: false, freshProcessReads: true, openedSettings: false)
        #expect(s == .switchedOnNeedsReopen)
        #expect(s.reopenNote != nil)
    }

    @Test(arguments: [false as Bool?, nil])
    func afterOpeningSettingsTheButtonIsOfferedAnyway(fresh: Bool?) {
        let s = ScreenRecordingStep(reads: false, freshProcessReads: fresh, openedSettings: true)
        #expect(s == .mayNeedReopen)
        #expect(s.reopenNote != nil)
    }

    @Test(arguments: [false as Bool?, nil])
    func noButtonBeforeTheUserHasDoneAnything(fresh: Bool?) {
        let s = ScreenRecordingStep(reads: false, freshProcessReads: fresh, openedSettings: false)
        #expect(s == .notAllowed)
        #expect(s.reopenNote == nil)
    }
}
