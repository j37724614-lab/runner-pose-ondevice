/// Pose-only jump event detection (core/longjump/detection.py): trim, flight, sand landing and
/// take-off timing.  Indices are track indices; ranges are half-open like the Python tuples.
public enum JumpEventDetection {

    // MARK: - numpy-style helpers

    /// `array[start:end]` with Python slice semantics (negative indices count from the end, both
    /// ends clamp).
    static func pySlice<T>(_ values: [T], _ start: Int, _ end: Int) -> [T] {
        let n = values.count
        var s = start < 0 ? start + n : start
        var e = end < 0 ? end + n : end
        s = Swift.min(Swift.max(s, 0), n)
        e = Swift.min(Swift.max(e, 0), n)
        return s < e ? Array(values[s..<e]) : []
    }

    /// `array[index]` with Python negative-index wrap.
    static func pyAt<T>(_ values: [T], _ index: Int) -> T {
        values[index < 0 ? index + values.count : index]
    }

    /// np.sort: NaN last.
    static func npSorted(_ values: [Double]) -> [Double] {
        values.filter { !$0.isNaN }.sorted() + values.filter { $0.isNaN }
    }

    // MARK: - Trim

    /// Exclusive end index of the jump clip; keeps the whole clip when a step fails
    /// (detection.find_trim_end).
    public static func findTrimEnd(_ track: PoseTrack, rule: TrimRule = TrimRule()) -> TrimResult {
        let speed = NP.medianFilterNearest(track.hipSpeedTowardPit(), size: rule.speedSmoothing)
        let coarse = NP.percentile(speed, rule.coarsePercentile)
        let threshold = rule.fastRatio * coarse
        guard let fast = Runs.longestTrueRun(speed.map { $0 >= threshold }) else {
            return TrimResult(endIndex: speed.count, fastSegment: nil)
        }
        let reference = NP.median(Array(speed[fast]))
        let slowLimit = rule.slowRatio * reference
        let anchor = Runs.firstSustained(speed.map { $0 < slowLimit }, start: fast.upperBound, hold: rule.slowHold)
        let end = anchor.map { findGettingUpIndex(track, anchor: $0, rule: rule) } ?? speed.count
        return TrimResult(endIndex: end, fastSegment: fast, referenceSpeed: reference, anchorIndex: anchor)
    }

    /// Lowest bbox height within settle_window of the anchor (sitting), then the first frame where
    /// the height stays >= rise_ratio x that minimum for rise_hold frames; that frame + 1
    /// (detection.find_getting_up_index).
    static func findGettingUpIndex(_ track: PoseTrack, anchor: Int, rule: TrimRule) -> Int {
        let heights = NP.medianFilterNearest(track.boxHeights, size: rule.heightSmoothing)
        let window = pySlice(heights, anchor, anchor + rule.settleWindow)
        guard !window.isEmpty else { return heights.count }
        let sitting = anchor + NP.argmin(window)
        let limit = rule.riseRatio * heights[sitting]
        let risen = heights.map { $0 >= limit }
        guard let up = Runs.firstSustained(risen, start: sitting, hold: rule.riseHold) else { return heights.count }
        return up + 1
    }
}
