import AppKit
import TallshotCore

/// Saves a diagnostic report for a capture that stopped early, only when the user turned the
/// setting on: a folder next to the capture with the frames as PNGs and a plain-text step log
/// (requested and measured scroll distance, line-up scores, the region and the app's name).
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
        guard let d = result.diagnostics else { return nil }
        var dir = folder.appendingPathComponent("\(baseName) diagnostics", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = folder.appendingPathComponent("\(baseName) diagnostics \(n)", isDirectory: true)
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            let r = target.region
            let region = "\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width)) x \(Int(r.height)) points, \(target.kind.rawValue)"
                + (target.isBrowserLike ? ", browser-like app" : "") + (target.scrollBar != nil ? ", settable scroll bar" : "")
            let text = d.text(reason: result.reason, region: region, appName: target.appName + (target.bundleID.map { " (\($0))" } ?? ""), result: result)
            try Data(text.utf8).write(to: dir.appendingPathComponent("report.txt"), options: .withoutOverwriting)
            for (number, frame) in d.frames {
                guard let cg = WindowCapturer.cgImage(frame, colorSpace: colorSpace), let png = Delivery.pngData(cg) else { continue }
                try png.write(to: dir.appendingPathComponent(String(format: "frame-%04d.png", number)), options: .withoutOverwriting)
            }
            return dir
        } catch {
            return nil
        }
    }
}
