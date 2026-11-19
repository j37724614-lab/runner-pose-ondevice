import Foundation

/// The numpy / scipy operations the server's long-jump code uses, re-implemented to give the
/// same doubles (summation order, interpolation formula and edge handling included).
///
/// Checked value by value against the real libraries:
/// `Tests/LongJumpKitTests/Fixtures/unit/numerics.json` (scripts/longjump/make_unit_fixtures.py).
public enum NP {

    // MARK: - Element-wise / shape helpers

    /// `np.diff`: `out[i] = values[i + 1] - values[i]`.
    public static func diff(_ values: [Double]) -> [Double] {
        guard values.count > 1 else { return [] }
        return (0..<(values.count - 1)).map { values[$0 + 1] - values[$0] }
    }

    /// `np.gradient` with unit spacing and `edge_order=1`: central differences inside, one-sided
    /// differences at both ends.  Needs at least two values (numpy raises otherwise; here `[]`
    /// for an empty input and `[0]` for one value).
    public static func gradient(_ values: [Double]) -> [Double] {
        let n = values.count
        guard n >= 2 else { return n == 1 ? [0] : [] }
        var out = [Double](repeating: 0, count: n)
        out[0] = (values[1] - values[0]) / 1.0
        out[n - 1] = (values[n - 1] - values[n - 2]) / 1.0
        if n > 2 {
            for i in 1..<(n - 1) {
                out[i] = (values[i + 1] - values[i - 1]) / 2.0
            }
        }
        return out
    }

    /// `np.minimum` (NaN propagates).
    public static func minimum(_ a: [Double], _ b: [Double]) -> [Double] {
        precondition(a.count == b.count)
        return zip(a, b).map { x, y in (x.isNaN || y.isNaN) ? .nan : Swift.min(x, y) }
    }

    /// `np.maximum` (NaN propagates).
    public static func maximum(_ a: [Double], _ b: [Double]) -> [Double] {
        precondition(a.count == b.count)
        return zip(a, b).map { x, y in (x.isNaN || y.isNaN) ? .nan : Swift.max(x, y) }
    }

    // MARK: - NaN filling (core.longjump.detection.fill_nan)

    /// `fill_nan`: non-finite values replaced by `np.interp` over the finite ones (edge values
    /// held); unchanged when fewer than two values are finite.
    public static func fillNaN(_ values: [Double]) -> [Double] {
        let finite = values.indices.filter { values[$0].isFinite }
        guard finite.count >= 2 else { return values }
        let xp = finite.map(Double.init)
        let fp = finite.map { values[$0] }
        var out = values
        for i in values.indices where !values[i].isFinite {
            out[i] = interp(Double(i), xp: xp, fp: fp)
        }
        return out
    }

    /// `np.interp` for one point (xp increasing): numpy's formula, including its NaN retry.
    public static func interp(_ x: Double, xp: [Double], fp: [Double]) -> Double {
        precondition(!xp.isEmpty && xp.count == fp.count)
        let last = xp.count - 1
        if x <= xp[0] { return fp[0] }
        if x >= xp[last] { return fp[last] }
        // j: xp[j] <= x < xp[j + 1]
        var low = 0
        var high = last
        while high - low > 1 {
            let mid = (low + high) / 2
            if xp[mid] <= x { low = mid } else { high = mid }
        }
        let j = low
        let slope = (fp[j + 1] - fp[j]) / (xp[j + 1] - xp[j])
        var result = slope * (x - xp[j]) + fp[j]
        if result.isNaN {
            result = slope * (x - xp[j + 1]) + fp[j + 1]
            if result.isNaN && fp[j] == fp[j + 1] { result = fp[j] }
        }
        return result
    }

    // MARK: - Filters

    /// `scipy.ndimage.median_filter(values, size=size, mode="nearest")` for an odd `size`:
    /// window centred on each element, edges repeat the end values.
    public static func medianFilterNearest(_ values: [Double], size: Int) -> [Double] {
        precondition(size >= 1 && size % 2 == 1, "only odd sizes are used (and mirrored)")
        let n = values.count
        guard n > 0, size > 1 else { return values }
        let half = size / 2
        var window = [Double](repeating: 0, count: size)
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            for k in 0..<size {
                let j = Swift.min(Swift.max(i + k - half, 0), n - 1)
                window[k] = values[j]
            }
            window.sort()
            out[i] = window[half]
        }
        return out
    }

    // MARK: - Reductions

    /// `np.sum` of doubles: numpy's pairwise summation (8-way unrolled blocks of up to 128).
    public static func sum(_ values: [Double]) -> Double {
        values.withUnsafeBufferPointer { pairwiseSum($0[...]) }
    }

    private static func pairwiseSum(_ a: Slice<UnsafeBufferPointer<Double>>) -> Double {
        let n = a.count
        let base = a.startIndex
        if n < 8 {
            var res = 0.0
            for i in 0..<n { res += a[base + i] }
            return res
        }
        if n <= 128 {
            var r = (0..<8).map { a[base + $0] }
            var i = 8
            while i < n - (n % 8) {
                for j in 0..<8 { r[j] += a[base + i + j] }
                i += 8
            }
            var res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]))
            while i < n {
                res += a[base + i]
                i += 1
            }
            return res
        }
        var n2 = n / 2
        n2 -= n2 % 8
        return pairwiseSum(a[base..<(base + n2)]) + pairwiseSum(a[(base + n2)..<(base + n)])
    }

    /// `np.mean`: `np.sum / count` (NaN when empty).
    public static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : sum(values) / Double(values.count)
    }

    /// `np.nanmean`: NaN treated as 0 in numpy's sum, divided by the non-NaN count.
    public static func nanMean(_ values: [Double]) -> Double {
        let count = values.reduce(0) { $0 + ($1.isNaN ? 0 : 1) }
        guard count > 0 else { return .nan }
        return sum(values.map { $0.isNaN ? 0 : $0 }) / Double(count)
    }

    /// `np.median` (NaN when any value is NaN or the input is empty).
    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty, !values.contains(where: \.isNaN) else { return .nan }
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }

    /// `np.nanmedian` (NaN when every value is NaN).
    public static func nanMedian(_ values: [Double]) -> Double {
        median(values.filter { !$0.isNaN })
    }

    /// `np.percentile(values, q)` with the default "linear" method (q in 0...100); NaN when any
    /// value is NaN.
    public static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty, !values.contains(where: \.isNaN) else { return .nan }
        let sorted = values.sorted()
        let n = sorted.count
        let quantile = q / 100.0
        let virtual = Double(n - 1) * quantile
        var previous = virtual.rounded(.down)
        var gamma: Double
        let lower: Double
        let upper: Double
        if virtual >= Double(n - 1) {
            previous = -1
            gamma = virtual - previous
            lower = sorted[n - 1]
            upper = sorted[n - 1]
        } else if virtual < 0 {
            gamma = virtual - 0
            lower = sorted[0]
            upper = sorted[0]
        } else {
            gamma = virtual - previous
            lower = sorted[Int(previous)]
            upper = sorted[Int(previous) + 1]
        }
        return lerp(lower, upper, gamma)
    }

    /// numpy's `_lerp`: `a + (b - a) * t`, but `b - (b - a) * (1 - t)` when `t >= 0.5`.
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let difference = b - a
        return t >= 0.5 ? b - difference * (1 - t) : a + difference * t
    }

    /// `np.nanmax` (NaN when every value is NaN).
    public static func nanMax(_ values: [Double]) -> Double {
        values.filter { !$0.isNaN }.max() ?? .nan
    }

    /// `np.nanmin` (NaN when every value is NaN).
    public static func nanMin(_ values: [Double]) -> Double {
        values.filter { !$0.isNaN }.min() ?? .nan
    }

    /// `np.nanargmin`: first index of the smallest non-NaN value; nil when all are NaN (numpy
    /// raises).
    public static func nanArgmin(_ values: [Double]) -> Int? {
        var best: Int?
        for (i, v) in values.enumerated() where !v.isNaN {
            if best == nil || v < values[best!] { best = i }
        }
        return best
    }

    /// `np.nanargmax`: first index of the largest non-NaN value; nil when all are NaN.
    public static func nanArgmax(_ values: [Double]) -> Int? {
        var best: Int?
        for (i, v) in values.enumerated() where !v.isNaN {
            if best == nil || v > values[best!] { best = i }
        }
        return best
    }

    /// `np.argmin`: first index of the smallest value; the first NaN wins when there is one.
    public static func argmin(_ values: [Double]) -> Int {
        precondition(!values.isEmpty)
        if let nan = values.firstIndex(where: \.isNaN) { return nan }
        var best = 0
        for i in values.indices where values[i] < values[best] { best = i }
        return best
    }

    /// `np.argmax`: first index of the largest value; the first NaN wins when there is one.
    public static func argmax(_ values: [Double]) -> Int {
        precondition(!values.isEmpty)
        if let nan = values.firstIndex(where: \.isNaN) { return nan }
        var best = 0
        for i in values.indices where values[i] > values[best] { best = i }
        return best
    }
}
