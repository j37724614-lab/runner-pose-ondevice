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
            let tdSelection = JumpEventDetection.selectBoardContactFromSpeed(speed, flightStart: flightStart, rule: rule)
            let toRun = JumpEventDetection.supportRunFromSpeed(speed, flightStart: flightStart, threshold: rule.toeOffMaxStillSpeedPerS, rule: rule)
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
}
