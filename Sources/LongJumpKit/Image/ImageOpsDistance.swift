import Foundation

extension ImageOps {
    /// cv2.distanceTransform(mask, cv2.DIST_L2, 5): distance of every non-zero pixel to the
    /// nearest zero pixel (OpenCV 4.13's float 5x5 chamfer with metrics 1 / 1.4 / 2.1969; an
    /// image without zero pixels stays at FLT_MAX).
    public static func distanceTransformL2x5(_ mask: BinaryMask) -> Grid<Float> {
        let w = mask.width, h = mask.height
        guard w > 0, h > 0 else { return Grid(width: w, height: h, repeating: 0) }
        let a: Float = 1.0, b: Float = 1.4, c: Float = 2.1969
        let initDist = Float.greatestFiniteMagnitude
        let border = 2
        let tw = w + 2 * border
        var temp = [Float](repeating: initDist, count: tw * (h + 2 * border))
        var out = [Float](repeating: 0, count: w * h)
        mask.data.withUnsafeBufferPointer { src in
            temp.withUnsafeMutableBufferPointer { t in
                out.withUnsafeMutableBufferPointer { dist in
                    // forward pass
                    for i in 0..<h {
                        let base = (i + border) * tw + border
                        for j in 0..<w {
                            let p = base + j
                            if src[i * w + j] == 0 {
                                t[p] = 0
                            } else {
                                var t0 = t[p - tw * 2 - 1] + c
                                var v = t[p - tw * 2 + 1] + c
                                if v < t0 { t0 = v }
                                v = t[p - tw - 2] + c
                                if v < t0 { t0 = v }
                                v = t[p - tw - 1] + b
                                if v < t0 { t0 = v }
                                v = t[p - tw] + a
                                if v < t0 { t0 = v }
                                v = t[p - tw + 1] + b
                                if v < t0 { t0 = v }
                                v = t[p - tw + 2] + c
                                if v < t0 { t0 = v }
                                v = t[p - 1] + a
                                if v < t0 { t0 = v }
                                t[p] = t0
                            }
                        }
                    }
                    // backward pass
                    for i in stride(from: h - 1, through: 0, by: -1) {
                        let base = (i + border) * tw + border
                        for j in stride(from: w - 1, through: 0, by: -1) {
                            let p = base + j
                            var t0 = t[p]
                            if t0 > a {
                                var v = t[p + tw * 2 + 1] + c
                                if v < t0 { t0 = v }
                                v = t[p + tw * 2 - 1] + c
                                if v < t0 { t0 = v }
                                v = t[p + tw + 2] + c
                                if v < t0 { t0 = v }
                                v = t[p + tw + 1] + b
                                if v < t0 { t0 = v }
                                v = t[p + tw] + a
                                if v < t0 { t0 = v }
                                v = t[p + tw - 1] + b
                                if v < t0 { t0 = v }
                                v = t[p + tw - 2] + c
                                if v < t0 { t0 = v }
                                v = t[p + 1] + a
                                if v < t0 { t0 = v }
                                t[p] = t0
                            }
                            dist[i * w + j] = t0
                        }
                    }
                }
            }
        }
        return Grid(width: w, height: h, values: out)
    }
}
