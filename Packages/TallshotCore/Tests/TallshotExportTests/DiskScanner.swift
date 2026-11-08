import Compression
import CoreGraphics
import Foundation
import PDFKit
import TallshotCore
import TallshotExport

extension Data {
    /// Whether `needle` occurs in these bytes (memmem: much faster than `range(of:)`).
    func has(_ needle: Data) -> Bool {
        guard !needle.isEmpty, needle.count <= count else { return false }
        return withUnsafeBytes { h in needle.withUnsafeBytes { n in memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil } }
    }
}

/// Looks for a capture's content inside files the way a person would find it: PNGs are decoded to
/// pixels, PDF streams are unpacked and their text and information read, Word files are unzipped.
/// Searching a file's raw bytes misses all of these, because PNG, PDF and Word data is compressed.
struct DiskScanner {
    /// Words that only the test capture contains.
    var texts: [String]
    /// Rows of the test capture's pixels, as stored (BGRA, 4 bytes per pixel).
    var rows: [[UInt32]] { didSet { forms = rows.flatMap(Self.byteForms) } }
    private var forms: [Data]

    init(texts: [String], rows: [[UInt32]]) {
        self.texts = texts
        self.rows = rows
        forms = rows.flatMap(Self.byteForms)
    }

    /// What was found in `data`, such as "text" or "pixels" (empty when nothing).
    func findings(in data: Data, depth: Int = 0) -> Set<String> {
        guard depth < 4, !data.isEmpty else { return [] }
        var found = Set<String>()
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            if let image = decodePNG(data), containsRow(image) { found.insert("pixels") }
        } else if data.starts(with: Array("%PDF".utf8)) {
            if let pdf = PDFDocument(data: data) {
                let words = (pdf.string ?? "") + " " + (pdf.documentAttributes ?? [:]).values.map { "\($0)" }.joined(separator: " ")
                if texts.contains(where: { words.contains($0) }) { found.insert("text") }
            }
            for stream in Self.pdfStreams(data) { found.formUnion(findings(inRaw: stream)) }
        } else if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            for (_, entry) in Zip.entries(data) { found.formUnion(findings(in: entry, depth: depth + 1)) }
        }
        found.formUnion(findings(inRaw: data))
        return found
    }

    /// Plain bytes: the words (UTF-8 or UTF-16) and the pixel rows as BGRA, RGBA or RGB.
    func findings(inRaw data: Data) -> Set<String> {
        var found = Set<String>()
        if texts.contains(where: { t in
            data.has(Data(t.utf8)) || [String.Encoding.utf16BigEndian, .utf16LittleEndian].contains { e in
                t.data(using: e).map { data.has($0) } ?? false }
        }) { found.insert("text") }
        if forms.contains(where: { data.has($0) }) { found.insert("pixels") }
        return found
    }

    func containsRow(_ image: PixelImage) -> Bool {
        let wanted = Set(rows.map { $0 })
        for y in 0..<image.height where wanted.contains(Array(image.row(y))) { return true }
        // A crop or a wider image: look for the row's bytes anywhere.
        let bytes = image.pixels.withUnsafeBytes { Data($0) }
        return rows.contains { bytes.has(Self.byteForms($0)[0]) }
    }

    /// A row as BGRA (how Tallshot stores it), RGBA and RGB (how a PDF may store it).
    static func byteForms(_ row: [UInt32]) -> [Data] {
        var bgra = Data(), rgba = Data(), rgb = Data()
        for p in row {
            let b = UInt8(p & 0xFF), g = UInt8((p >> 8) & 0xFF), r = UInt8((p >> 16) & 0xFF), a = UInt8(p >> 24)
            bgra += [b, g, r, a]; rgba += [r, g, b, a]; rgb += [r, g, b]
        }
        return [bgra, rgba, rgb]
    }

    /// Every stream in a PDF, unpacked when it is Flate-compressed (the usual kind).
    static func pdfStreams(_ pdf: Data) -> [Data] {
        var out: [Data] = []
        let start = Data("stream".utf8), end = Data("endstream".utf8)
        var cursor = pdf.startIndex
        while let s = pdf.range(of: start, in: cursor..<pdf.endIndex) {
            var body = s.upperBound
            if body < pdf.endIndex, pdf[body] == 0x0D { body += 1 }
            if body < pdf.endIndex, pdf[body] == 0x0A { body += 1 }
            guard let e = pdf.range(of: end, in: body..<pdf.endIndex) else { break }
            let raw = pdf[body..<e.lowerBound]
            out.append(Data(raw))
            if let unpacked = inflate(Data(raw)) { out.append(unpacked) }
            cursor = e.upperBound
        }
        return out
    }

    /// zlib data (a 2-byte header, then raw deflate) unpacked, or nil.
    static func inflate(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let body = data.dropFirst(2)
        var capacity = max(1 << 16, body.count * 8)
        while capacity <= 1 << 30 {
            var out = Data(count: capacity)
            let n = out.withUnsafeMutableBytes { dst in
                body.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              src.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n == 0 { return nil }
            if n < capacity { return out.prefix(n) }
            capacity *= 4
        }
        return nil
    }

    /// Files under `roots` changed since `date`, outside `skipping`, that hold any of the content,
    /// with what was found in each.
    /// `topLevelOnly` folders are searched without going into their subfolders.
    func scan(_ roots: [URL], topLevelOnly: [URL] = [], changedSince date: Date, skipping: [URL]) -> [String: Set<String>] {
        var hits: [String: Set<String>] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        let skip = skipping.map { $0.resolvingSymlinksInPath().path }
        for (root, shallow) in roots.map({ ($0, false) }) + topLevelOnly.map({ ($0, true) }) {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                         options: shallow ? [.skipsSubdirectoryDescendants] : [],
                                                         errorHandler: { _, _ in true }) else { continue }
            while let url = e.nextObject() as? URL {
                let path = url.resolvingSymlinksInPath().path
                if skip.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { e.skipDescendants(); continue }
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let m = v.contentModificationDate, m >= date, let size = v.fileSize, size > 0, size < 300_000_000,
                      let data = try? Data(contentsOf: url, options: .alwaysMapped) else { continue }
                let f = findings(in: data)
                if !f.isEmpty { hits[path] = f }
            }
        }
        return hits
    }
}
