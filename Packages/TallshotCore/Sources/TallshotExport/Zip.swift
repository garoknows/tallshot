import Foundation

/// A tiny ZIP writer and reader for stored (uncompressed) entries: enough for a .docx, which
/// is a ZIP of XML files. Written here so Tallshot needs no third-party code.
public enum Zip {
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    /// A ZIP archive holding `entries` in order, stored without compression.
    public static func archive(_ entries: [(name: String, data: Data)]) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { var x = UInt16(truncatingIfNeeded: v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        func u32(_ v: UInt32, _ d: inout Data) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        for e in entries {
            let name = Data(e.name.utf8), crc = crc32(e.data), offset = UInt32(out.count)
            u32(0x0403_4B50, &out); u16(20, &out); u16(0x0800, &out); u16(0, &out); u16(0, &out); u16(0x21, &out)
            u32(crc, &out); u32(UInt32(e.data.count), &out); u32(UInt32(e.data.count), &out)
            u16(name.count, &out); u16(0, &out); out.append(name); out.append(e.data)
            u32(0x0201_4B50, &central); u16(20, &central); u16(20, &central); u16(0x0800, &central); u16(0, &central)
            u16(0, &central); u16(0x21, &central); u32(crc, &central); u32(UInt32(e.data.count), &central)
            u32(UInt32(e.data.count), &central); u16(name.count, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(0, &central); u32(offset, &central); central.append(name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(entries.count, &out); u16(entries.count, &out)
        u32(UInt32(central.count), &out); u32(cdOffset, &out); u16(0, &out)
        return out
    }

    /// Reads a ZIP made of stored entries (used by the tests to look inside a .docx).
    public static func entries(_ zip: Data) -> [String: Data] {
        let b = [UInt8](zip)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var out: [String: Data] = [:], i = 0
        while i + 30 <= b.count, u32(i) == 0x0403_4B50 {
            let method = u16(i + 8), size = u32(i + 18), nameLen = u16(i + 26), extra = u16(i + 28)
            let name = String(decoding: b[(i + 30)..<(i + 30 + nameLen)], as: UTF8.self)
            let start = i + 30 + nameLen + extra
            guard method == 0, start + size <= b.count else { break }
            out[name] = Data(b[start..<(start + size)])
            i = start + size
        }
        return out
    }
}
