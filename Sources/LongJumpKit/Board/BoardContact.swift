import Foundation

extension BoardDetector {
    /// detection.find_board_contact_with_board: classify the toe-centre TD/TO interval against the
    /// board.  Toe-centre speed owns timing; board proximity selects the support side and
    /// BEFORE_BOARD / ON_BOARD / OVER_LINE.
    public static func findBoardContactWithBoard(
        track: PoseTrack,
        flightStart: Int,
        boardMask: BinaryMask,
        takeoffLine: TakeoffLine? = nil,
        pitSide: Side = .left,
        rule: BoardContactRule = BoardContactRule()
    ) -> BoardContactAssessment {
        // distance transform of the inverted board mask
        var inverted = boardMask
        for i in 0..<inverted.data.count { inverted.data[i] = inverted.data[i] != 0 ? 0 : 1 }
        let distance = ImageOps.distanceTransformL2x5(inverted)
        let heights = track.boxHeights
        let frameCount = track.count

        func distanceAt(_ p: SIMD2<Double>) -> Float? {
            guard p.x.isFinite, p.y.isFinite else { return nil }
            let column = min(max(PyRound.toInt(p.x), 0), distance.width - 1)
            let row = min(max(PyRound.toInt(p.y), 0), distance.height - 1)
            return distance[column, row]
        }

        // (touches_board, -minimum_board_distance, toe_off, side, contact): Python tuple max
        var best: (touches: Bool, negDistance: Double, toeOff: Int, side: Side, contact: Int)?
        for side in [Side.left, Side.right] {
            let speed = track.toeCenterSpeed2DPerS(side, smoothing: rule.speedSmoothing)
            let tdSelection = selectBoardContact(speed, flightStart: flightStart, rule: rule)
            let toRun = supportRun(speed, flightStart: flightStart, threshold: rule.toeOffMaxStillSpeedPerS, rule: rule)
            guard let contact = tdSelection.index, let toeOff = toRun?.1 else { continue }
            let joints = ["heel", "big_toe", "small_toe"].map { track.jointXY("\(side.rawValue)_\($0)") }
            var near = [Bool](repeating: false, count: frameCount)
            for index in 0..<frameCount {
                var minimum: Float?
                for joint in joints {
                    if let d = distanceAt(joint[index]) { minimum = minimum.map { Swift.min($0, d) } ?? d }
                }
                if let minimum { near[index] = Double(minimum) <= rule.boardDistanceRatio * heights[index] }
            }
            var boardDistances: [Double] = []
            if contact <= toeOff {
                for stance in contact...toeOff {
                    for joint in joints {
                        if let d = distanceAt(joint[stance]) { boardDistances.append(Double(d)) }
                    }
                }
            }
            let minimumBoardDistance = boardDistances.isEmpty ? Double.infinity : boardDistances.min()!
            let touches = contact <= toeOff && near[contact...toeOff].contains(true)
            let candidate = (touches: touches, negDistance: -minimumBoardDistance, toeOff: toeOff, side: side, contact: contact)
            if best == nil || tupleGreater(candidate, best!) { best = candidate }
        }
        guard let chosen = best else { return BoardContactAssessment(footSide: nil, boardContactIndex: nil, toeOffIndex: nil) }
        let minimumBoardDistance = -chosen.negDistance
        let side = chosen.side, contact = chosen.contact, toeOff = chosen.toeOff
        guard let line = takeoffLine else {
            return BoardContactAssessment(
                footSide: side, boardContactIndex: contact, toeOffIndex: toeOff,
                takeoffPosition: chosen.touches ? .onBoard : .beforeBoard,
                minBoardDistancePx: minimumBoardDistance
            )
        }
        let toes = ["big_toe", "small_toe"].map { track.jointXY("\(side.rawValue)_\($0)") }
        var minClearance = Double.nan
        var clearanceIndex = 0
        var first = true
        if contact <= toeOff {
            for index in contact...toeOff {
                for toe in toes {
                    let p = toe[index]
                    let lineX = line.x(atY: p.y)
                    let clearance = pitSide == .left ? p.x - lineX : lineX - p.x
                    // Python min() over (clearance, index) tuples
                    if first || tupleLess(clearance, index, minClearance, clearanceIndex) {
                        minClearance = clearance
                        clearanceIndex = index
                        first = false
                    }
                }
            }
        }
        let position: TakeoffPosition = minClearance < 0 ? .overLine : (chosen.touches ? .onBoard : .beforeBoard)
        return BoardContactAssessment(
            footSide: side, boardContactIndex: contact, toeOffIndex: toeOff,
            minToeClearancePx: minClearance, clearanceFrameIndex: clearanceIndex,
            toeOverLine: minClearance < 0, takeoffPosition: position, minBoardDistancePx: minimumBoardDistance
        )
    }

    /// Python `(a0, a1) < (b0, b1)` for (float, int) tuples (NaN never compares less).
    private static func tupleLess(_ a0: Double, _ a1: Int, _ b0: Double, _ b1: Int) -> Bool {
        if a0 != b0 { return a0 < b0 }
        return a1 < b1
    }

    /// Python tuple comparison `a > b` for (bool, float, int, str, int).
    private static func tupleGreater(
        _ a: (touches: Bool, negDistance: Double, toeOff: Int, side: Side, contact: Int),
        _ b: (touches: Bool, negDistance: Double, toeOff: Int, side: Side, contact: Int)
    ) -> Bool {
        if a.touches != b.touches { return a.touches && !b.touches }
        if a.negDistance != b.negDistance { return a.negDistance > b.negDistance }
        if a.toeOff != b.toeOff { return a.toeOff > b.toeOff }
        if a.side != b.side { return a.side.rawValue > b.side.rawValue }
        return a.contact > b.contact
    }

    // MARK: TD / TO support runs (detection._support_run_from_speed, _select_board_contact_from_speed)

    /// detection._bridge_short_breaks.
    static func bridgeShortBreaks(_ still: [Bool], maxFrames: Int) -> [Bool] {
        var bridged = still
        var index = 0
        while index < still.count {
            if still[index] { index += 1; continue }
            var end = index
            while end < still.count && !still[end] { end += 1 }
            if 0 < index && end < still.count && end - index <= maxFrames {
                for k in index..<end { bridged[k] = true }
            }
            index = end
        }
        return bridged
    }

    /// detection._support_run_from_speed.
    static func supportRun(_ speed: [Double], flightStart: Int, threshold: Double, rule: BoardContactRule) -> (Int, Int)? {
        let still = bridgeShortBreaks(speed.map { $0 < threshold }, maxFrames: rule.maxBridgeFrames)
        var index = Swift.min(flightStart - 1, still.count - 1)
        while index > 0 && !still[index] {
            index -= 1
            if flightStart - index > rule.maxGapBeforeFlight { return nil }
        }
        if !still[index] { return nil }
        let end = index
        while index > 0 && still[index - 1] && flightStart - index < rule.maxFramesBack { index -= 1 }
        return (index, end)
    }

    /// detection._adaptive_board_contact_from_speed.
    static func adaptiveBoardContact(_ speed: [Double], flightStart: Int, rule: BoardContactRule) -> Int? {
        let valleyStart = Swift.max(0, flightStart - rule.adaptiveValleyLookbackFrames)
        let valleyEnd = Swift.max(valleyStart + 1, flightStart - 1)
        if valleyStart >= speed.count || valleyEnd > speed.count { return nil }
        let valley = Array(speed[valleyStart..<valleyEnd])
        if valley.isEmpty { return nil }
        let anchor = valleyStart + NP.argmin(valley)
        let floorCount = Swift.min(rule.adaptiveFloorSamples, valley.count)
        let floor = NP.median(Array(valley.sorted()[..<floorCount]))
        let edge = Swift.max(0, anchor - rule.adaptiveReferenceLookbackFrames)
        let reference = NP.percentile(Array(speed[edge...anchor]), rule.adaptiveReferencePercentile)
        let threshold = floor + rule.adaptiveTdRatio * Swift.max(0.0, reference - floor)
        let low = bridgeShortBreaks(speed.map { $0 < threshold }, maxFrames: rule.maxBridgeFrames)
        var index = anchor
        while index > edge && low[index - 1] { index -= 1 }
        return Swift.max(index, flightStart - rule.maxFramesBack)
    }

    /// detection._select_board_contact_from_speed.
    static func selectBoardContact(_ speed: [Double], flightStart: Int, rule: BoardContactRule, scaleSpeed: [Double]? = nil) -> BoardContactSelection {
        let support = supportRun(speed, flightStart: flightStart, threshold: rule.maxStillSpeedPerS, rule: rule)
        guard let fixed = support?.0 else { return BoardContactSelection(index: nil, mode: "no_fixed_support") }
        guard let adaptive = adaptiveBoardContact(speed, flightStart: flightStart, rule: rule) else {
            return BoardContactSelection(index: fixed, mode: "fixed_no_adaptive")
        }
        let precontactStart = Swift.max(0, adaptive - rule.adaptiveReferenceLookbackFrames)
        let scale = scaleSpeed ?? speed
        let precontact = precontactStart < adaptive ? Array(scale[precontactStart..<adaptive]) : []
        if precontact.count < rule.adaptiveFloorSamples {
            return BoardContactSelection(index: fixed, mode: "fixed_insufficient_scale_samples")
        }
        let reference = NP.percentile(precontact, rule.adaptiveReferencePercentile)
        let belowFraction = Double(precontact.filter { $0 < rule.maxStillSpeedPerS }.count) / Double(precontact.count)
        let informative = reference >= rule.maxStillSpeedPerS * rule.fixedTdMinReferenceRatio
            && belowFraction < rule.fixedTdMaxPrecontactBelowFraction
        if !informative {
            return BoardContactSelection(index: adaptive, mode: "adaptive_slow_speed_scale", referenceSpeed: reference, precontactBelowFixedFraction: belowFraction)
        }
        if abs(fixed - adaptive) > rule.adaptiveTdMaxDisagreementFrames {
            return BoardContactSelection(index: adaptive, mode: "adaptive_fixed_disagreement", referenceSpeed: reference, precontactBelowFixedFraction: belowFraction)
        }
        return BoardContactSelection(index: fixed, mode: "fixed_informative_speed_scale", referenceSpeed: reference, precontactBelowFixedFraction: belowFraction)
    }
}
