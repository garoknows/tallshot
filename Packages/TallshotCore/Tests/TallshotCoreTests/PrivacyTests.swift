import Foundation
import Testing
import TallshotCore

@Suite("Private and safe")
@MainActor
struct PrivacyTests {
    /// A capture leaves no trace on disk: after a full capture of a page with a unique pattern,
    /// no file written since the test started, in the temp folder or the user's caches,
    /// contains any of its pixel rows.
    @Test func framesNeverReachDisk() async throws {
        let started = Date().addingTimeInterval(-1)
        let w = SimulatedWindow(pageHeight: 3000, seed: 0xC0FFEE)
        let r = try await CaptureSession(driver: w).run()
        #expect(r.reason == .bottom)
        // Three distinctive rows of the result, as raw bytes.
        let needles: [Data] = [400, 1500, 2600].map { y in r.image.row(y).withUnsafeBytes { Data($0) } }
        for hit in filesContaining(needles, writtenSince: started) {
            Issue.record("frame bytes found in \(hit)")
        }
    }

    /// With the diagnostics setting off (the default), a capture that stops early keeps no
    /// frames for a report and leaves nothing on disk.
    @Test func earlyStopWithDiagnosticsOffWritesNothing() async throws {
        let started = Date().addingTimeInterval(-1)
        let w = SimulatedWindow(pageHeight: 4000, seed: 0xBADC0DE)
        w.replaceContentAfterScrolls = 3
        let r = try await CaptureSession(driver: w).run()
        #expect(r.reason.isEarly)
        #expect(r.diagnostics == nil)
        let needles: [Data] = [100, 300].map { y in r.image.row(y).withUnsafeBytes { Data($0) } }
        #expect(filesContaining(needles, writtenSince: started).isEmpty)
    }

}

/// Files in the temp folder and the user's caches, written since `date`, that contain any needle.
func filesContaining(_ needles: [Data], writtenSince date: Date) -> [String] {
    var hits: [String] = []
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
    let roots = [FileManager.default.temporaryDirectory, FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]]
    for root in roots {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
                                                     errorHandler: { _, _ in true }) else { continue }
        while let url = e.nextObject() as? URL {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let m = v.contentModificationDate, m >= date,
                  let size = v.fileSize, size >= needles[0].count, size < 200_000_000,
                  let data = try? Data(contentsOf: url, options: .alwaysMapped) else { continue }
            if needles.contains(where: { data.range(of: $0) != nil }) { hits.append(url.lastPathComponent) }
        }
    }
    return hits
}
