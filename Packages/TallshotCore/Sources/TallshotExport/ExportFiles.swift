import Foundation

/// Writes finished exports into the folder the user chose, and nowhere else. Everything is
/// built in memory first; this is the only place the exports touch the disk.
public enum ExportFiles {
    /// `baseName`, or the same with " 2", " 3" if a file with any of these extensions already
    /// exists, so a set of files stays together. The number goes before `ending` if the name has
    /// it: "Notes - 2026-11-07 at 14.05 2 - Tallshot".
    public static func uniqueBaseName(_ baseName: String, extensions: [String], folder: URL, ending: String = "") -> String {
        let stem = !ending.isEmpty && baseName.hasSuffix(ending) ? String(baseName.dropLast(ending.count)) : baseName
        let tail = stem.count == baseName.count ? "" : ending
        var base = baseName, n = 2
        while extensions.contains(where: { FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(base).\($0)").path) }) {
            base = "\(stem) \(n)\(tail)"; n += 1
        }
        return base
    }

    /// What a write managed: the files saved, by extension, and the error that stopped it.
    public struct Written {
        public var files: [String: URL] = [:]
        public var error: Error?
    }

    /// Writes each (extension, data) as "<baseName>.<extension>" in `folder`, never overwriting.
    /// Pick the name with `uniqueBaseName` first: it isn't changed here, so the name inside the
    /// files (the PDF title, the Markdown image link) stays right. On a failure, the files already
    /// saved are kept and returned, and a partly written file of its own is removed.
    public static func write(_ files: [(ext: String, data: Data)], baseName: String, folder: URL) -> Written {
        var out = Written()
        for f in files {
            let url = folder.appendingPathComponent("\(baseName).\(f.ext)")
            let existed = FileManager.default.fileExists(atPath: url.path)
            do {
                try f.data.write(to: url, options: .withoutOverwriting)   // straight into the folder: no temp copy elsewhere
                out.files[f.ext] = url
            } catch {
                if !existed { try? FileManager.default.removeItem(at: url) }
                out.error = error
                break
            }
        }
        return out
    }
}
