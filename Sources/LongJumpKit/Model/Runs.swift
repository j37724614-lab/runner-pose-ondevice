/// Small helpers several long-jump modules share (detection.true_runs / longest_true_run /
/// first_sustained / _local_ground_y).

public enum Runs {
    /// Every run of consecutive `true` values as [start, end), skipping runs shorter than
    /// `minLength` (detection.true_runs).
    public static func trueRuns(_ mask: [Bool], minLength: Int = 1) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for index in 0...mask.count {
            let value = index < mask.count && mask[index]
            if value, start == nil {
                start = index
            } else if !value, let s = start {
                if index - s >= minLength { runs.append(s..<index) }
                start = nil
            }
        }
        return runs
    }

    /// The longest run (the first one wins ties), or nil (detection.longest_true_run).
    public static func longestTrueRun(_ mask: [Bool], minLength: Int = 1) -> Range<Int>? {
        var best: Range<Int>?
        for run in trueRuns(mask, minLength: minLength) where best == nil || run.count > best!.count {
            best = run
        }
        return best
    }

    /// First index >= start where `condition` stays true for `hold` frames
    /// (detection.first_sustained; like the Python, the last `hold` start positions are not tried).
    public static func firstSustained(_ condition: [Bool], start: Int, hold: Int) -> Int? {
        guard start < condition.count - hold else { return nil }
        for index in start..<(condition.count - hold) where condition[index..<(index + hold)].allSatisfy({ $0 }) {
            return index
        }
        return nil
    }

    /// Ground y2 at `index`: the smaller of max(y2) over the `reach` frames before and after it (a
    /// side without finite values is skipped); nil when neither side has one
    /// (detection._local_ground_y).
    public static func localGroundY(_ bottomY: [Double], index: Int, reach: Int) -> Double? {
        let before = bottomY[Swift.max(0, index - reach)..<index]
        let afterEnd = Swift.min(bottomY.count, index + 1 + reach)
        let after = index + 1 < afterEnd ? bottomY[(index + 1)..<afterEnd] : bottomY[0..<0]
        let maxima = [before, after].compactMap { window -> Double? in
            guard window.contains(where: { $0.isFinite }) else { return nil }
            return NP.nanMax(Array(window))
        }
        return maxima.min()
    }
}
