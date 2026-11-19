/// takeoff_board.find_partial_board's result: the visible sliver of a board covered by a take-off
/// aid.  `lineWorldX` is the take-off line (the sliver's pit-side edge) as pit world X.
public struct PartialBoard: Sendable, Equatable {
    public var score: Double
    public var edgePx: SIMD2<Double>
    public var lineWorldX: Double
    /// x1, y1, x2, y2 of the sliver.
    public var bbox: [Int]
    public var offsetM: Double
    public var nearEnd: Double
    public var intoPit: Double
}

extension TakeoffCheck {
    /// takeoff_board.find_partial_board: small white blobs near the take-off toe whose pit-side
    /// edge maps 1-3 m before the pit; the one nearest `boardOffsetM` wins.  Needs the pit
    /// calibration (the line is that edge's world X).
    public static func findPartialBoard(
        image: PixelImage, toePx: SIMD2<Double>, homography: PitHomography, runSide: Side,
        boardOffsetM: Double = PitCalibration.defaultBoardOffsetM
    ) -> PartialBoard? {
        let nearEnd = PitHomography.nearEndFromDirection(homography, runSide: runSide)
        let farEnd = nearEnd == homography.xRange.0 ? homography.xRange.1 : homography.xRange.0
        let intoPit = farEnd > nearEnd ? 1.0 : -1.0
        let (dx, above, below) = partialSearchPx
        let tx = toePx.x
        let ty = toePx.y
        let components = ImageOps.connectedComponentsWithStats(BoardDetector.whiteMask(image))
        var best: PartialBoard?
        guard components.count > 1 else { return nil }
        for label in 1..<components.count {
            let s = components.stats[label]
            if s.area < partialMinArea || s.width < 2 * s.height { continue }
            let cx = Double(s.x) + Double(s.width) / 2
            let cy = Double(s.y) + Double(s.height) / 2
            if Swift.abs(cx - tx) > Double(dx) || !(ty - Double(above) <= cy && cy <= ty + Double(below)) { continue }
            var rows: [Double] = []
            var edgeX: [Double] = []
            for row in 0..<s.height {
                let y = s.y + row
                var low = -1
                var high = -1
                for x in s.x..<(s.x + s.width) where components.labels[y * components.width + x] == Int32(label) {
                    if low < 0 { low = x }
                    high = x
                }
                guard low >= 0 else { continue }
                rows.append(Double(row))
                edgeX.append(Double(runSide == .left ? low : high))
            }
            let edge = SIMD2(NP.mean(edgeX), NP.mean(rows) + Double(s.y))
            let lineX = homography.toWorld(edge).x
            let offset = (nearEnd - lineX) * intoPit
            guard boardOffsetRangeM.0 <= offset && offset <= boardOffsetRangeM.1 else { continue }
            let score = Swift.abs(offset - boardOffsetM)
            if best == nil || score < best!.score {
                best = PartialBoard(
                    score: score, edgePx: edge, lineWorldX: lineX,
                    bbox: [s.x, s.y, s.x + s.width, s.y + s.height],
                    offsetM: offset, nearEnd: nearEnd, intoPit: intoPit
                )
            }
        }
        return best
    }

    /// assess_partial_takeoff against a `findPartialBoard` result.
    public static func assessPartialTakeoff(
        track: PoseTrack, events: JumpEvents, board: PartialBoard, homography: PitHomography
    ) -> (check: JSONValue?, draw: JSONValue?, line: TakeoffLine?) {
        assessPartialTakeoff(
            track: track, events: events, lineWorldX: board.lineWorldX, intoPit: board.intoPit,
            edgePx: board.edgePx, bbox: board.bbox, homography: homography
        )
    }
}
