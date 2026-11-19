import Foundation

/// An 8-bit HSV image (OpenCV convention, H in 0...179), interleaved H, S, V.
public struct HSVImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// width * height * 3 bytes, no row padding.
    public var data: [UInt8]
}

/// Re-implementations of the OpenCV 4.13 functions the long-jump analysis uses, bit-exact.
public enum ImageOps {
    // MARK: BGR -> HSV (cv2.COLOR_BGR2HSV, 8-bit), modules/imgproc/src/color_hsv.simd.hpp RGB2HSV_b

    static let hsvShift = 12

    static let sdivTable: [Int32] = {
        var t = [Int32](repeating: 0, count: 256)
        for i in 1..<256 { t[i] = Int32((Double(255 << hsvShift) / Double(i)).rounded(.toNearestOrEven)) }
        return t
    }()

    static let hdivTable180: [Int32] = {
        var t = [Int32](repeating: 0, count: 256)
        for i in 1..<256 { t[i] = Int32((Double(180 << hsvShift) / (6.0 * Double(i))).rounded(.toNearestOrEven)) }
        return t
    }()

    /// One pixel's (h, s, v) from its blue, green and red bytes.
    @inline(__always)
    static func hsv(
        _ b: Int32, _ g: Int32, _ r: Int32,
        sdiv: UnsafePointer<Int32>, hdiv: UnsafePointer<Int32>
    ) -> (h: UInt8, s: UInt8, v: UInt8) {
        let v = max(b, max(g, r))
        let vmin = min(b, min(g, r))
        let diff = v - vmin
        let vr: Int32 = v == r ? -1 : 0
        let vg: Int32 = v == g ? -1 : 0
        let half: Int32 = 1 << Int32(hsvShift - 1)
        let s = (diff &* sdiv[Int(v)] &+ half) >> Int32(hsvShift)
        var h = (vr & (g - b)) + (~vr & ((vg & (b - r + 2 * diff)) + ((~vg) & (r - g + 4 * diff))))
        h = (h &* hdiv[Int(diff)] &+ half) >> Int32(hsvShift)
        if h < 0 { h += 180 }
        return (UInt8(truncatingIfNeeded: min(max(h, 0), 255)), UInt8(truncatingIfNeeded: s), UInt8(v))
    }

    /// Calls `body(index, h, s, v)` for every pixel, row-major, without allocating.
    @inline(__always)
    static func forEachHSV(_ image: PixelImage, _ body: (Int, UInt8, UInt8, UInt8) -> Void) {
        let channels = image.layout.channels
        let (bo, ro): (Int, Int)
        switch image.layout {
        case .bgr, .bgra: (bo, ro) = (0, 2)
        case .rgb, .rgba: (bo, ro) = (2, 0)
        }
        let width = image.width
        let stride = image.bytesPerRow
        sdivTable.withUnsafeBufferPointer { sdiv in
            hdivTable180.withUnsafeBufferPointer { hdiv in
                image.data.withUnsafeBufferPointer { px in
                    for y in 0..<image.height {
                        var p = y * stride
                        var i = y * width
                        for _ in 0..<width {
                            let c = hsv(Int32(px[p + bo]), Int32(px[p + 1]), Int32(px[p + ro]),
                                        sdiv: sdiv.baseAddress!, hdiv: hdiv.baseAddress!)
                            body(i, c.h, c.s, c.v)
                            p += channels
                            i += 1
                        }
                    }
                }
            }
        }
    }

    /// cv2.cvtColor(image, cv2.COLOR_BGR2HSV) for an 8-bit image.
    public static func bgrToHSV(_ image: PixelImage) -> HSVImage {
        var out = [UInt8](repeating: 0, count: image.width * image.height * 3)
        out.withUnsafeMutableBufferPointer { o in
            forEachHSV(image) { i, h, s, v in
                o[i * 3] = h
                o[i * 3 + 1] = s
                o[i * 3 + 2] = v
            }
        }
        return HSVImage(width: image.width, height: image.height, data: out)
    }
}
