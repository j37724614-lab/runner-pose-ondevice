extension JumpEventDetection {

    /// Python `max(0.0, x)`: x only when x > 0 (NaN gives 0).
    private static func pyMaxZero(_ x: Double) -> Double { x > 0.0 ? x : 0.0 }

    /// Fill runs of at most `maxFrames` false that have true on both sides
    /// (detection._bridge_short_breaks).
    static func bridgeShortBreaks(_ still: [Bool], maxFrames: Int) -> [Bool] {
        var bridged = still
        var index = 0
        while index < still.count {
            if still[index] {
                index += 1
                continue
            }
            var end = index
            while end < still.count && !still[end] { end += 1 }
            if 0 < index && end < still.count && end - index <= maxFrames {
                for k in index..<end { bridged[k] = true }
            }
            index = end
        }
        return bridged
    }

    /// Slower of both feet's toe-centre speed (detection._minimum_toe_center_speed).
    static func minimumToeCenterSpeed(_ track: PoseTrack, smoothing: Int) -> [Double] {
        NP.minimum(track.toeCenterSpeed2DPerS(.left, smoothing: smoothing),
                   track.toeCenterSpeed2DPerS(.right, smoothing: smoothing))
    }

    static func footStill(_ track: PoseTrack, rule: BoardContactRule, threshold: Double? = nil) -> [Bool] {
        let speed = minimumToeCenterSpeed(track, smoothing: rule.speedSmoothing)
        let limit = threshold ?? rule.maxStillSpeedPerS
        return bridgeShortBreaks(speed.map { $0 < limit }, maxFrames: rule.maxBridgeFrames)
    }

    /// Low-speed toe-centre run nearest the first airborne frame, as inclusive (start, end)
    /// (detection._support_run_from_flight).
    static func supportRunFromFlight(
        _ track: PoseTrack, flightStart: Int, threshold: Double, rule: BoardContactRule
    ) -> (start: Int, end: Int)? {
        supportRunFromSpeed(
            minimumToeCenterSpeed(track, smoothing: rule.speedSmoothing),
            flightStart: flightStart, threshold: threshold, rule: rule)
    }

    /// detection._support_run_from_speed.
    static func supportRunFromSpeed(
        _ speed: [Double], flightStart: Int, threshold: Double, rule: BoardContactRule
    ) -> (start: Int, end: Int)? {
        let still = bridgeShortBreaks(speed.map { $0 < threshold }, maxFrames: rule.maxBridgeFrames)
        guard !still.isEmpty else { return nil }
        var index = Swift.min(flightStart - 1, still.count - 1)
        while index > 0 && !still[index] {
            index -= 1
            if flightStart - index > rule.maxGapBeforeFlight { return nil }
        }
        if !pyAt(still, index) { return nil }
        let end = index
        while index > 0 && still[index - 1] && flightStart - index < rule.maxFramesBack {
            index -= 1
        }
        return (index, end)
    }

    /// detection._adaptive_board_contact_from_speed.
    static func adaptiveBoardContactFromSpeed(
        _ speed: [Double], flightStart: Int, rule: BoardContactRule
    ) -> Int? {
        let valleyStart = Swift.max(0, flightStart - rule.adaptiveValleyLookbackFrames)
        let valleyEnd = Swift.max(valleyStart + 1, flightStart - 1)
        if valleyStart >= speed.count || valleyEnd > speed.count { return nil }
        let valley = Array(speed[valleyStart..<valleyEnd])
        if valley.isEmpty { return nil }
        let anchor = valleyStart + NP.argmin(valley)
        let floorCount = Swift.min(rule.adaptiveFloorSamples, valley.count)
        let floor = NP.median(Array(npSorted(valley)[..<floorCount]))
        let edge = Swift.max(0, anchor - rule.adaptiveReferenceLookbackFrames)
        let reference = NP.percentile(Array(speed[edge..<(anchor + 1)]), rule.adaptiveReferencePercentile)
        let threshold = floor + rule.adaptiveTdRatio * pyMaxZero(reference - floor)
        let low = bridgeShortBreaks(speed.map { $0 < threshold }, maxFrames: rule.maxBridgeFrames)
        var index = anchor
        while index > edge && low[index - 1] { index -= 1 }
        return Swift.max(index, flightStart - rule.maxFramesBack)
    }

    /// Fixed TD only when 3.55 separates this trial's swing and support, otherwise the adaptive
    /// valley (detection._select_board_contact_from_speed).
    public static func selectBoardContactFromSpeed(
        _ speed: [Double], flightStart: Int, rule: BoardContactRule = BoardContactRule(),
        scaleSpeed: [Double]? = nil
    ) -> BoardContactSelection {
        let support = supportRunFromSpeed(speed, flightStart: flightStart, threshold: rule.maxStillSpeedPerS, rule: rule)
        let adaptive = adaptiveBoardContactFromSpeed(speed, flightStart: flightStart, rule: rule)
        guard let fixed = support?.start else {
            return BoardContactSelection(index: nil, mode: "no_fixed_support")
        }
        guard let adaptive else {
            return BoardContactSelection(index: fixed, mode: "fixed_no_adaptive")
        }
        let precontactStart = Swift.max(0, adaptive - rule.adaptiveReferenceLookbackFrames)
        let precontact = pySlice(scaleSpeed ?? speed, precontactStart, adaptive)
        if precontact.count < rule.adaptiveFloorSamples {
            return BoardContactSelection(index: fixed, mode: "fixed_insufficient_scale_samples")
        }
        let reference = NP.percentile(precontact, rule.adaptiveReferencePercentile)
        let below = Double(precontact.filter { $0 < rule.maxStillSpeedPerS }.count) / Double(precontact.count)
        let informative = reference >= rule.maxStillSpeedPerS * rule.fixedTdMinReferenceRatio
            && below < rule.fixedTdMaxPrecontactBelowFraction
        if !informative {
            return BoardContactSelection(
                index: adaptive, mode: "adaptive_slow_speed_scale",
                referenceSpeed: reference, precontactBelowFixedFraction: below)
        }
        if Swift.abs(fixed - adaptive) > rule.adaptiveTdMaxDisagreementFrames {
            return BoardContactSelection(
                index: adaptive, mode: "adaptive_fixed_disagreement",
                referenceSpeed: reference, precontactBelowFixedFraction: below)
        }
        return BoardContactSelection(
            index: fixed, mode: "fixed_informative_speed_scale",
            referenceSpeed: reference, precontactBelowFixedFraction: below)
    }

    /// TD from fixed speed when informative, otherwise from the local valley
    /// (detection.find_board_contact).
    public static func findBoardContact(
        _ track: PoseTrack, flightStart: Int, rule: BoardContactRule = BoardContactRule()
    ) -> Int? {
        let left = track.toeCenterSpeed2DPerS(.left, smoothing: rule.speedSmoothing)
        let right = track.toeCenterSpeed2DPerS(.right, smoothing: rule.speedSmoothing)
        return selectBoardContactFromSpeed(
            NP.minimum(left, right), flightStart: flightStart, rule: rule,
            scaleSpeed: NP.maximum(left, right)).index
    }

    /// TO: final frame of the toe-centre run below the 1.15 heights/s threshold
    /// (detection.find_toe_off).
    public static func findToeOff(
        _ track: PoseTrack, boardContact: Int?, rule: BoardContactRule = BoardContactRule(),
        flightStart: Int? = nil
    ) -> Int? {
        if let flightStart {
            return supportRunFromFlight(
                track, flightStart: flightStart, threshold: rule.toeOffMaxStillSpeedPerS, rule: rule)?.end
        }
        guard let boardContact else { return nil }
        let still = footStill(track, rule: rule, threshold: rule.toeOffMaxStillSpeedPerS)
        var index = boardContact
        while index + 1 < still.count && !still[index] {
            index += 1
            if index - boardContact > rule.maxGapBeforeFlight { return nil }
        }
        while index + 1 < still.count && still[index + 1] { index += 1 }
        return index
    }
}
