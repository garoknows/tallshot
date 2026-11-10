import AppKit
import TallshotCore
import TallshotExport

/// Saves a diagnostic report for a capture that stopped early, only when the user turned the
/// setting on. It goes next to the capture, or in the folder chosen for reports. The writing
/// itself is `DiagnosticsReport` (in TallshotExport, where the privacy tests run it).
/// It stays on this Mac. Nothing is ever sent anywhere, and nothing is written when it is off.
@MainActor
enum DiagnosticsWriter {
    /// Whether a report should be written. With the setting off, the capture never even keeps
    /// the frames (`CaptureOptions.keepDiagnostics` is false), so `result.diagnostics` is nil.
    static func shouldWrite(settingOn: Bool, result: CaptureResult) -> Bool {
        settingOn && result.reason.isEarly && result.diagnostics != nil
    }

    /// Writes "Tallshot … diagnostics" in `folder`. Returns the folder, or nil if it failed.
    static func write(_ result: CaptureResult, target: CaptureTarget, colorSpace: CGColorSpace, folder: URL, baseName: String) -> URL? {
        let r = target.region
        let region = "\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width)) x \(Int(r.height)) points, \(target.kind.rawValue)"
            + (target.isBrowserLike ? ", browser-like app" : "") + (target.scrollBar != nil ? ", settable scroll bar" : "")
        let app = target.appName + (target.bundleID.map { " (\($0))" } ?? "")
        return DiagnosticsReport.write(result, region: region, appName: app, colorSpace: colorSpace, folder: folder, baseName: baseName)
    }
}
