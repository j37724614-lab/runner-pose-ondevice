import Foundation

/// Take-off board check: where the take-off toe stands against the board line (foul / on board /
/// before) (takeoff_board.py).  find_partial_board: Board/PartialBoard.swift.
public enum TakeoffCheck {
    /// World Athletics TR29: take-off board 1.22 m (across the runway) x 0.20 m (along the run).
    public static let boardWidthM = 0.20
    public static let boardLengthM = 1.22
    /// Toe this close to the line: the call is within the toe keypoint's noise.
    public static let lineUncertainM = 0.03
    /// Detected board line vs board_offset_m in the pit calibration: check the pit size.
    public static let boardOffsetMismatchM = 0.15
    public static let partialMinArea = 20
    /// Window around the take-off toe at TD: +-x, above, below.
    public static let partialSearchPx = (250, 30, 90)
    /// TR29: take-off line 1-3 m from the nearer end of the landing area.
    public static let boardOffsetRangeM = (1.0, 3.0)
    public static let partialUncertainM = 0.10

    /// Bounding box [x_min, y_min, x_max, y_max] of the set pixels.
    static func maskBBox(_ mask: BinaryMask) -> [Int]? {
        var xMin = Int.max, yMin = Int.max, xMax = -1, yMax = -1
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask.data[y * mask.width + x] != 0 {
                xMin = Swift.min(xMin, x); xMax = Swift.max(xMax, x)
                yMin = Swift.min(yMin, y); yMax = Swift.max(yMax, y)
            }
        }
        return xMax < 0 ? nil : [xMin, yMin, xMax, yMax]
    }

    private static func pair(_ a: Double, _ b: Double) -> JSONValue { .array([.double(a), .double(b)]) }

    /// takeoff_board.assess_takeoff: (public take-off check, drawing data) from the detected board;
    /// (nil, nil) without a board assessment.
    public static func assessTakeoff(
        track: PoseTrack, events: JumpEvents?, board: BoardView?, runSide: Side,
        homography: PitHomography? = nil
    ) -> (check: JSONValue?, draw: JSONValue?) {
        guard let assessment = events?.takeoffAssessment, let position = assessment.takeoffPosition else {
            return (nil, nil)
        }
        var check = JSONObject()
        check["position"] = .string(position.rawValue)
        check["foul"] = .bool(position == .overLine)
        check["uncertain"] = .bool(false)
        check["foot"] = JSONValue(assessment.footSide?.rawValue)
        check["frame"] = .null
        check["time_s"] = .null
        check["toe_to_line_m"] = .null
        check["toe_to_line_px"] = .null
        check["board_width_px"] = .null
        check["scale"] = .null
        check["toe_to_line_m_pit"] = .null
        check["line_source"] = .string("board")
        guard let takeoffLine = board?.line, let board, let index = assessment.clearanceFrameIndex,
              assessment.minToeClearancePx != nil, let footSide = assessment.footSide
        else {
            return (.object(check), nil)
        }
        var toe: SIMD2<Double>?
        var clearance: Double?
        for joint in ["big_toe", "small_toe"] {
            let p = DistanceMeasurement.jointPoint(track, "\(footSide.rawValue)_\(joint)", index)
            guard p.x.isFinite && p.y.isFinite else { continue }
            let gap = runSide == .left ? p.x - takeoffLine.x(atY: p.y) : takeoffLine.x(atY: p.y) - p.x
            if clearance == nil || gap < clearance! {
                toe = p
                clearance = gap
            }
        }
        guard let toe, let clearance else { return (.object(check), nil) }
        let width = BoardDetector.boardRowWidthPx(board.mask)
        let metres: Double? = (width != nil && width != 0) ? boardWidthM * clearance / width! : nil
        var pitMetres: Double?
        if let homography {
            let toeWorld = homography.toWorld(toe)
            let lineWorld = homography.toWorld(SIMD2(takeoffLine.x(atY: toe.y), toe.y))
            pitMetres = copysign(Swift.abs(toeWorld.x - lineWorld.x), clearance)
        }
        let frame = track.frames[index]
        check["frame"] = .int(frame)
        check["time_s"] = .double(PyRound.numpy(Double(frame) / track.fps, 4))
        check["toe_to_line_px"] = .double(PyRound.python(clearance, 1))
        check["toe_to_line_m"] = metres.map { .double(PyRound.python($0, 3)) } ?? .null
        check["board_width_px"] = width.map { .double(PyRound.python($0, 1)) } ?? .null
        check["scale"] = metres != nil ? .string("board_width_0.20m") : .null
        check["toe_to_line_m_pit"] = pitMetres.map { .double(PyRound.python($0, 3)) } ?? .null
        check["uncertain"] = .bool(metres.map { Swift.abs($0) < lineUncertainM } ?? false)
        guard let bbox = maskBBox(board.mask) else { return (.object(check), nil) }
        let draw: JSONValue = .object([
            "toe_px": pair(toe.x, toe.y),
            "line": .array([pair(takeoffLine.top.x, takeoffLine.top.y), pair(takeoffLine.bottom.x, takeoffLine.bottom.y)]),
            "board_bbox": .array(bbox.map { .int($0) }),
        ])
        return (.object(check), draw)
    }

    /// takeoff_board.assess_partial_takeoff against the line of a partly covered board
    /// (`lineWorldX`, `intoPit`, `edgePx`, `bbox` are find_partial_board's fields), in metres.
    public static func assessPartialTakeoff(
        track: PoseTrack, events: JumpEvents, lineWorldX: Double, intoPit: Double,
        edgePx: SIMD2<Double>, bbox: [Int], homography: PitHomography
    ) -> (check: JSONValue?, draw: JSONValue?, line: TakeoffLine?) {
        let foot = track.takeoffFoot(events)
        let byFrame = track.indexByFrame()
        guard let foot, let boardContact = events.boardContact, let toeOff = events.toeOff,
              let td = byFrame[boardContact], let to = byFrame[toeOff]
        else { return (nil, nil, nil) }
        var best: (clearance: Double, index: Int, toe: SIMD2<Double>)?
        for index in Swift.min(td, to)...Swift.max(td, to) {
            for joint in ["big_toe", "small_toe"] {
                let point = DistanceMeasurement.jointPoint(track, "\(foot.rawValue)_\(joint)", index)
                guard point.x.isFinite && point.y.isFinite else { continue }
                let clearance = -((homography.toWorld(point).x - lineWorldX) * intoPit)
                if best == nil || clearance < best!.clearance { best = (clearance, index, point) }
            }
        }
        guard let best else { return (nil, nil, nil) }
        let (clearance, index, toe) = best
        let toeYWorld = homography.toWorld(toe).y
        let boardYWorld = homography.toWorld(edgePx).y
        let low = Swift.min(toeYWorld, boardYWorld) - 0.3
        let high = Swift.max(toeYWorld, boardYWorld) + 0.3
        let ends = homography.toImage([SIMD2(lineWorldX, low), SIMD2(lineWorldX, high)])
        let (a, b) = (ends[0], ends[1])
        let (top, bottom) = a.y <= b.y ? (a, b) : (b, a)
        let line = TakeoffLine(top: top, bottom: bottom)
        let position: TakeoffPosition =
            clearance < 0 ? .overLine : (clearance <= boardWidthM ? .onBoard : .beforeBoard)
        let check: JSONValue = .object([
            "position": .string(position.rawValue),
            "foul": .bool(clearance < 0),
            "uncertain": .bool(Swift.abs(clearance) < partialUncertainM),
            "foot": .string(foot.rawValue),
            "frame": .int(track.frames[index]),
            "time_s": .double(PyRound.numpy(Double(track.frames[index]) / track.fps, 4)),
            "toe_to_line_m": .double(PyRound.python(clearance, 3)),
            "toe_to_line_px": .null,
            "board_width_px": .null,
            "scale": .string("pit_homography"),
            "toe_to_line_m_pit": .double(PyRound.python(clearance, 3)),
            "line_source": .string("board_partial"),
        ])
        let xs = [top.x, bottom.x, Double(bbox[0]), Double(bbox[2]), toe.x]
        let ys = [top.y, bottom.y, Double(bbox[1]), Double(bbox[3]), toe.y]
        let draw: JSONValue = .object([
            "toe_px": pair(toe.x, toe.y),
            "line": .array([pair(line.top.x, line.top.y), pair(line.bottom.x, line.bottom.y)]),
            "board_bbox": .array([
                .int(Int(xs.min()!)), .int(Int(ys.min()!)), .int(Int(xs.max()!)), .int(Int(ys.max()!)),
            ]),
            "visible_board_bbox": .array(bbox.map { .int($0) }),
        ])
        return (check, draw, line)
    }

    /// takeoff_board._check_board_line_against_pit: where the detected board line falls in the pit
    /// calibration (should be board_offset_m before the pit).
    static func checkBoardLineAgainstPit(
        _ result: inout JSONObject, homography: PitHomography, takeoffDraw: JSONValue,
        takeoffLine: TakeoffLine, pit: PitCalibration
    ) {
        let toeY = takeoffDraw["toe_px"]?.arrayValue?[1].doubleValue ?? .nan
        let lineWorld = homography.toWorld(SIMD2(takeoffLine.x(atY: toeY), toeY))
        let nearEnd = result["distance"]?["pit_near_end_x_m"]?.doubleValue ?? .nan
        let gap = Swift.abs(lineWorld.x - nearEnd)
        var takeoff = result["takeoff"] ?? .object(JSONObject())
        takeoff["board_line_to_pit_edge_m"] = .double(PyRound.python(gap, 3))
        result["takeoff"] = takeoff
        if Swift.abs(gap - pit.boardOffsetM) > boardOffsetMismatchM {
            var warnings = result["warnings"]?.arrayValue ?? []
            warnings.append(.string("board_offset_mismatch"))
            result["warnings"] = .array(warnings)
        }
    }
}
