extension JumpEventDetection {
    /// detection.detect_jump_events: flight, take-off (TD/TO), apex and sand landing of one attempt,
    /// plus the board assessment when a board was detected; nil when there is no flight.
    public static func detectJumpEvents(_ track: PoseTrack, board: BoardView? = nil, pitSide: Side = .left) -> JumpEvents? {
        guard let flight = findFlight(track) else { return nil }
        var assessment: BoardContactAssessment?
        if let board {
            assessment = BoardDetector.findBoardContactWithBoard(
                track: track, flightStart: flight.lowerBound, boardMask: board.mask,
                takeoffLine: board.line, pitSide: pitSide
            )
        }
        let boardIndex = findBoardContact(track, flightStart: flight.lowerBound)
        let toeOffIndex = findToeOff(track, boardContact: boardIndex, flightStart: flight.lowerBound)
        if assessment != nil {
            assessment!.boardContactIndex = boardIndex
            assessment!.toeOffIndex = toeOffIndex
        }
        let bottomY = track.bottomY
        let sandIndex = findSandLanding(bottomY: bottomY, flight: flight, boxHeights: track.boxHeights, fps: track.fps)
        func frame(_ index: Int?) -> Int? { index.map { track.frames[$0] } }
        return JumpEvents(
            flightStart: track.frames[flight.lowerBound],
            flightEnd: track.frames[flight.upperBound - 1],
            apex: track.frames[flightApex(bottomY: bottomY, flight: flight)],
            boardContact: frame(boardIndex),
            toeOff: frame(toeOffIndex),
            sandLanding: frame(sandIndex),
            takeoffAssessment: assessment,
            sandLandingReview: reviewSandLanding(sandIndex, flight: flight, fps: track.fps)
        )
    }
}
