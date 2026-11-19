import Foundation

extension ImageOps {
    /// OpenCV's cv::RNG (multiply-with-carry).
    struct CVRNG {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0xFFFF_FFFF : seed }
        mutating func next() -> UInt32 {
            state = UInt64(UInt32(truncatingIfNeeded: state)) &* 4_164_903_690 &+ (state >> 32)
            return UInt32(truncatingIfNeeded: state)
        }
        mutating func uniform(_ a: Int, _ b: Int) -> Int {
            a == b ? a : Int(Int32(truncatingIfNeeded: next() % UInt32(b - a) &+ UInt32(truncatingIfNeeded: a)))
        }
    }

    /// linefit.cpp fitLine2D_wods with weights.
    private static func fitWeighted(_ pts: [SIMD2<Float>], _ w: [Float], _ line: inout [Float]) {
        var x = 0.0, y = 0.0, x2 = 0.0, y2 = 0.0, xy = 0.0, sw = 0.0
        for i in 0..<pts.count {
            let px = pts[i].x, py = pts[i].y, wi = w[i]
            x += Double(wi * px)
            y += Double(wi * py)
            x2 += Double(wi * px * px)
            y2 += Double(wi * py * py)
            xy += Double(wi * px * py)
            sw += Double(wi)
        }
        x /= sw; y /= sw; x2 /= sw; y2 /= sw; xy /= sw
        let dx2 = x2 - x * x
        let dy2 = y2 - y * y
        let dxy = xy - x * y
        let t = Float(atan2(2 * dxy, dx2 - dy2)) / 2
        line[0] = Float(cos(Double(t)))
        line[1] = Float(sin(Double(t)))
        line[2] = Float(x)
        line[3] = Float(y)
    }

    /// cv2.fitLine(points, cv2.DIST_HUBER, 0, reps, aeps).ravel() for a 2D float32 point set:
    /// (vx, vy, x0, y0).
    public static func fitLineHuber(_ points: [SIMD2<Float>], reps: Float = 0.01, aeps: Float = 0.01) -> (vx: Float, vy: Float, x0: Float, y0: Float) {
        let count = points.count
        let eps = Double(count) * Double(Float.ulpOfOne)
        let rdelta: Float = reps != 0 ? reps : 1
        let adelta: Float = aeps != 0 ? aeps : 0.01
        let huberC: Float = 1.345
        var rng = CVRNG(seed: UInt64.max)
        var line = [Float](repeating: 0, count: 4)
        var cur = [Float](repeating: 0, count: 4)
        var prev = [Float](repeating: 0, count: 4)
        var w = [Float](repeating: 0, count: count)
        var r = [Float](repeating: 0, count: count)
        var minErr = Double.greatestFiniteMagnitude
        var err = 0.0
        for _ in 0..<20 {
            var first = true
            for i in 0..<count { w[i] = 0 }
            var i = 0
            while i < min(count, 10) {
                let j = rng.uniform(0, count)
                if w[j] < Float.ulpOfOne {
                    w[j] = 1
                    i += 1
                }
            }
            fitWeighted(points, w, &cur)
            for _ in 0..<30 {
                var sumW = 0.0
                if first {
                    first = false
                } else {
                    var t = Double(cur[0] * prev[0] + cur[1] * prev[1])
                    t = max(t, -1)
                    t = min(t, 1)
                    if abs(acos(t)) < Double(adelta) {
                        let x = abs(cur[2] - prev[2])
                        let y = abs(cur[3] - prev[3])
                        let d = x > y ? x : y
                        if d < rdelta { break }
                    }
                }
                for j in 0..<count {
                    let x = points[j].x - cur[2]
                    let y = points[j].y - cur[3]
                    r[j] = Float(abs(Double(cur[1] * x - cur[0] * y)))
                }
                err = 0
                for j in 0..<count { err += Double(r[j]) }
                if err < minErr {
                    minErr = err
                    line = cur
                    if err < eps { break }
                }
                for j in 0..<count { w[j] = r[j] < huberC ? 1.0 : huberC / r[j] }
                for j in 0..<count { sumW += Double(w[j]) }
                if abs(sumW) > Double(Float.ulpOfOne) {
                    sumW = 1.0 / sumW
                    for j in 0..<count { w[j] = Float(Double(w[j]) * sumW) }
                } else {
                    for j in 0..<count { w[j] = 1 }
                }
                prev = cur
                fitWeighted(points, w, &cur)
            }
        }
        return (line[0], line[1], line[2], line[3])
    }
}
