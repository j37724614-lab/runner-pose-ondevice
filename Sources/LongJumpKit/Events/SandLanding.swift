extension JumpEventDetection {

    /// Index of the sand touchdown from the bbox bottom y2: the deceleration peak
    /// (detection.find_sand_landing).  nil also where the Python would raise (no finite apex /
    /// steepest descent).
    public static func findSandLanding(
        bottomY: [Double],
        flight: Range<Int>,
        boxHeights: [Double],
        fps: Double,
        rule: SandLandingRule = SandLandingRule()
    ) -> Int? {
        let y2 = NP.fillNaN(bottomY)
        let smoothed = NP.medianFilterNearest(y2, size: rule.smoothing)
        let flightEnd = flight.upperBound
        guard let apex = apexIndex(smoothed, flight) else { return nil }
        let descent = NP.diff(smoothed)
        let searchEnd = Swift.min(flightEnd + rule.descentSearchAfterFlight, descent.count)
        guard let steepestOffset = NP.nanArgmax(pySlice(descent, apex, searchEnd)) else { return nil }
        let steepest = apex + steepestOffset
        let searchStart = Swift.max(steepest, flightEnd - rule.searchBeforeFlightEnd)

        let bodyHeight = NP.nanMedian(pySlice(boxHeights, flight.lowerBound, flightEnd))
        let speed = descent.map { $0 * fps / bodyHeight }
        var still: Int?
        let lastStart = speed.count - rule.stillFrames + 1
        if searchStart < lastStart {
            for index in searchStart..<lastStart
            where speed[index..<(index + rule.stillFrames)].allSatisfy({ $0 < rule.stillSpeedHeightsPerS }) {
                still = index
                break
            }
        }
        guard let still else { return nil }

        let velocity = NP.diff(NP.medianFilterNearest(y2, size: rule.decelerationSmoothing))
        let acceleration = NP.diff(velocity)
        let first = searchStart - 1
        let last = Swift.min(still + 1, acceleration.count)
        if last <= first { return nil }
        guard let peak = NP.nanArgmin(pySlice(acceleration, first, last)) else { return nil }
        return first + peak + 2
    }

    /// Reasons to check the landing by hand (detection.review_sand_landing).
    public static func reviewSandLanding(
        _ sandIndex: Int?, flight: Range<Int>, fps: Double, rule: SandLandingRule = SandLandingRule()
    ) -> [String] {
        guard let sandIndex else { return ["sand_landing_not_found"] }
        if Double(sandIndex - (flight.upperBound - 1)) > rule.maxAfterFlightS * fps {
            return ["sand_landing_late_after_flight"]
        }
        return []
    }
}
