import CoreGraphics
import Foundation
import ImageIO
import Testing
import TallshotCore
import TallshotExport

/// This process's memory footprint in bytes (what Activity Monitor's "Memory" column shows).
func memoryFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

/// Decodes PNG data back into 32-bit pixels in the same layout Tallshot uses (BGRA, premultiplied).
func decodePNG(_ data: Data) -> PixelImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    var px = [UInt32](repeating: 0, count: cg.width * cg.height)
    let ok = px.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return true
    }
    return ok ? PixelImage(width: cg.width, height: cg.height, pixels: px) : nil
}

@Suite("November 2026 review fixes: exports", .serialized)
struct ReviewExportTests {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // Finding 5: turning the capture into a CGImage must not copy all its pixels.
    @Test func makingACGImageDoesNotCopyThePixels() throws {
        let side = 5_000   // 25 million pixels: 100 MB
        let image = PixelImage(width: side, height: side, fill: 0xFF33_6699)
        let before = memoryFootprint()
        let cg = try #require(ImageBridge.cgImage(image, colorSpace: srgb))
        let grew = memoryFootprint() - before
        #expect(cg.width == side && cg.height == side)
        #expect(grew < 20_000_000, "making the CGImage added \(grew / 1_000_000) MB")
        withExtendedLifetime(cg) {}
    }

    @Test func theCGImageStillHasExactlyThePixels() throws {
        var image = PixelImage(width: 37, height: 23, fill: 0)
        for y in 0..<23 { for x in 0..<37 { image[x, y] = 0xFF00_0000 | UInt32(x * 6) << 16 | UInt32(y * 10) << 8 | UInt32((x + y) * 3) } }
        let cg = try #require(ImageBridge.cgImage(image, colorSpace: srgb))
        let png = try #require(ImageBridge.png(cg))
        #expect(decodePNG(png) == image)
        // A slice (as the PDF and Word pages use) reads the right rows too.
        let slice = try #require(cg.cropping(to: CGRect(x: 0, y: 10, width: 37, height: 5)))
        #expect(decodePNG(try #require(ImageBridge.png(slice))) == image.rows(10..<15))
    }
}
