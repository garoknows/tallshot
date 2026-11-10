import CoreGraphics
import Foundation
import TallshotCore

/// Saves a diagnostic report for a capture that stopped early: a folder with the kept frames as
/// PNGs and a plain-text step log (requested and measured scroll distance, line-up scores, the
/// region and the app's name). The app calls this only when the user turned the setting on.
/// It stays on this Mac. Nothing is ever sent anywhere.
public enum DiagnosticsReport {
    /// Writes "<baseName> diagnostics" (or " diagnostics 2", …) in `folder`. Returns the folder,
    /// or nil if there was nothing to write or it failed (then nothing is left behind).
    public static func write(_ result: CaptureResult, region: String, appName: String, colorSpace: CGColorSpace,
                             folder: URL, baseName: String) -> URL? {
        guard let d = result.diagnostics else { return nil }
        var dir = folder.appendingPathComponent("\(baseName) diagnostics", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = folder.appendingPathComponent("\(baseName) diagnostics \(n)", isDirectory: true)
            n += 1
        }
        var created = false
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            created = true
            let text = d.text(reason: result.reason, region: region, appName: appName, result: result)
            try Data(text.utf8).write(to: dir.appendingPathComponent("report.txt"), options: .withoutOverwriting)
            for (number, frame) in d.frames {
                guard let cg = ImageBridge.cgImage(frame, colorSpace: colorSpace), let png = ImageBridge.png(cg) else { continue }
                try png.write(to: dir.appendingPathComponent(String(format: "frame-%04d.png", number)), options: .withoutOverwriting)
            }
            return dir
        } catch {
            // No half-written report left behind (only the folder made just now).
            if created { try? FileManager.default.removeItem(at: dir) }
            return nil
        }
    }
}
