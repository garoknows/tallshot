import Foundation

/// Writes finished exports into the folder the user chose, and nowhere else. Everything is
/// built in memory first; this is the only place the exports touch the disk.
public enum ExportFiles {
    /// Writes each (extension, data) as "<baseName>.<extension>" in `folder`, never overwriting:
    /// if any name is taken, all of them get the same " 2", " 3" suffix so they stay together.
    /// Returns the files written, by extension.
    /// `baseName`, or "… 2", "… 3" if a file with any of these extensions already exists.
    public static func uniqueBaseName(_ baseName: String, extensions: [String], folder: URL) -> String {
        var base = baseName, n = 2
        while extensions.contains(where: { FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(base).\($0)").path) }) {
            base = "\(baseName) \(n)"; n += 1
        }
        return base
    }

    @discardableResult
    public static func write(_ files: [(ext: String, data: Data)], baseName: String, folder: URL) throws -> [String: URL] {
        let base = uniqueBaseName(baseName, extensions: files.map(\.ext), folder: folder)
        func url(_ ext: String) -> URL { folder.appendingPathComponent("\(base).\(ext)") }
        var out: [String: URL] = [:]
        for f in files {
            try f.data.write(to: url(f.ext), options: .withoutOverwriting)   // straight into the folder: no temp copy elsewhere
            out[f.ext] = url(f.ext)
        }
        return out
    }
}
