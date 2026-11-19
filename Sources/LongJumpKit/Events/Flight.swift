extension JumpEventDetection {

    /// [start, end) of the longest airborne run (detection.find_flight).
    public static func findFlight(_ track: PoseTrack, rule: FlightRule = FlightRule()) -> Range<Int>? {
        let bottomY = track.bottomY
        let heights = track.boxHeights
        let fps = track.fps
        let reach = Swift.max(1, PyRound.toInt(rule.groundReachS * fps))
        var airborne = [Bool](repeating: false, count: bottomY.count)
        for index in bottomY.indices {
            if let ground = Runs.localGroundY(bottomY, index: index, reach: reach) {
                airborne[index] = bottomY[index] < ground - rule.riseRatio * heights[index]
            }
        }
        return Runs.longestTrueRun(airborne, minLength: Swift.max(1, PyRound.toInt(rule.minFlightS * fps)))
    }

    /// Index of the highest point (smallest y2) inside the flight [start, end)
    /// (detection.flight_apex).  The Python raises when the slice has no finite value; the flight
    /// start is returned then.
    public static func flightApex(bottomY: [Double], flight: Range<Int>) -> Int {
        apexIndex(bottomY, flight) ?? flight.lowerBound
    }

    static func apexIndex(_ bottomY: [Double], _ flight: Range<Int>) -> Int? {
        NP.nanArgmin(pySlice(bottomY, flight.lowerBound, flight.upperBound)).map { flight.lowerBound + $0 }
    }
}
