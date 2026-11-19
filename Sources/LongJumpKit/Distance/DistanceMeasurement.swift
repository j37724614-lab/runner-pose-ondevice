import Foundation

/// Official / actual distance of a jump from the pit homography (distance.py).
public enum DistanceMeasurement {
    public static let minHeelScore = 0.35
    public static let calibrationRmsWarnM = 0.05
    public static let outsideMarginM = 0.10
    /// Toe at take-off may be up to this far past the line (foul) ...
    public static let toeCheckBeforeM = 0.40
    /// ... or this far behind it, for the calibration self-check.
    public static let toeCheckBehindM = 0.80
    /// A sand mark further behind the heels than this is a segmentation error.
    public static let maxMarkBehindHeelM = 1.5

    public enum FootKind {
        case toe
        case heel
    }

    /// distance._Landing.
    struct Landing {
        var world: SIMD2<Double>
        var px: SIMD2<Double>
        var name: String
        var score: Double
        var source: String
        var frame: Int
        var bodyPart: String?
    }

    /// One joint's image point at a track index (NaN when the track lacks the joint).
    static func jointPoint(_ track: PoseTrack, _ name: String, _ index: Int) -> SIMD2<Double> {
        guard let column = track.jointIndex[name] else { return SIMD2(.nan, .nan) }
        return track.jointsXY[index][column]
    }

    /// distance._event: `{"frame", "time_s"}` or null.
    static func event(_ track: PoseTrack, frame: Int?) -> JSONValue {
        guard let frame else { return .null }
        return .object([
            "frame": .int(frame),
            "time_s": .double(PyRound.numpy(Double(frame) / track.fps, 4)),
        ])
    }

    /// distance._foot_point: image point of one foot: heel (or ankle fallback) for landing, toe
    /// centre for take-off.
    static func footPoint(
        _ track: PoseTrack, index: Int, side: Side, kind: FootKind
    ) -> (point: SIMD2<Double>?, name: String, score: Double) {
        if kind == .toe {
            let names = PoseTrack.footJointsForSpeed.map { "\(side.rawValue)_\($0)" }
            let p0 = jointPoint(track, names[0], index)
            let p1 = jointPoint(track, names[1], index)
            let score = ((0 + track.jointScore(names[0], at: index)) + track.jointScore(names[1], at: index)) / 2
            let finite = p0.x.isFinite && p0.y.isFinite && p1.x.isFinite && p1.y.isFinite
            return (finite ? SIMD2((p0.x + p1.x) / 2, (p0.y + p1.y) / 2) : nil, "\(side.rawValue)_toe", score)
        }
        for name in ["\(side.rawValue)_heel", "\(side.rawValue)_ankle"] {
            guard track.jointIndex[name] != nil else { continue }
            let point = jointPoint(track, name, index)
            let score = track.jointScore(name, at: index)
            if point.x.isFinite && point.y.isFinite && score >= minHeelScore { return (point, name, score) }
        }
        return (nil, "\(side.rawValue)_heel", 0.0)
    }

    static func takeoffToeWorld(
        _ track: PoseTrack, _ events: JumpEvents, toeIndex: Int, _ homography: PitHomography
    ) -> (world: SIMD2<Double>?, name: String?) {
        // Only the foot standing on the board: the other foot is in the air.
        guard let side = track.takeoffFoot(events) else { return (nil, nil) }
        let (point, name, _) = footPoint(track, index: toeIndex, side: side, kind: .toe)
        guard let point else { return (nil, name) }
        return (homography.toWorld(point), name)
    }

    static func landingHeels(
        _ track: PoseTrack, landIndex: Int, _ homography: PitHomography
    ) -> [(world: SIMD2<Double>, point: SIMD2<Double>, name: String, score: Double)] {
        var heels: [(world: SIMD2<Double>, point: SIMD2<Double>, name: String, score: Double)] = []
        for side in [Side.left, Side.right] {
            let (point, name, score) = footPoint(track, index: landIndex, side: side, kind: .heel)
            if let point { heels.append((homography.toWorld(point), point, name, score)) }
        }
        return heels
    }

    /// distance._nearest_heel: the heel nearest the pit edge (first wins ties).
    static func nearestHeel(
        _ heels: [(world: SIMD2<Double>, point: SIMD2<Double>, name: String, score: Double)],
        nearEnd: Double, frame: Int
    ) -> Landing {
        var best = heels[0]
        for item in heels.dropFirst() where Swift.abs(item.world.x - nearEnd) < Swift.abs(best.world.x - nearEnd) {
            best = item
        }
        return Landing(world: best.world, px: best.point, name: best.name, score: best.score, source: "heel", frame: frame, bodyPart: "foot")
    }

    /// distance._signed_into_pit: (signed distance into the pit along the run, run sign).
    static func signedIntoPit(_ landingWorld: SIMD2<Double>, nearEnd: Double, _ homography: PitHomography) -> (Double, Double) {
        let farEnd = nearEnd == homography.xRange.0 ? homography.xRange.1 : homography.xRange.0
        let direction = farEnd > nearEnd ? 1.0 : -1.0
        return ((landingWorld.x - nearEnd) * direction, direction)
    }

    /// distance._prefer_sand_mark.
    static func preferSandMark(
        landing: Landing, signedIntoPit: Double, sandMark: SandMark, _ homography: PitHomography,
        nearEnd: Double, direction: Double, warnings: inout [String]
    ) -> (landing: Landing, signedIntoPit: Double, markIntoPit: Double) {
        let markPx = SIMD2(Double(sandMark.imagePx.x), Double(sandMark.imagePx.y))
        let markWorld = homography.toWorld(markPx)
        let markIntoPit = (markWorld.x - nearEnd) * direction
        var landing = landing
        var signed = signedIntoPit
        if markIntoPit < signed {
            if signed - markIntoPit <= maxMarkBehindHeelM {
                let joint = sandMark.joint.flatMap { $0.isEmpty ? nil : $0 } ?? "silhouette"
                landing = Landing(
                    world: markWorld, px: markPx, name: joint, score: 1.0, source: "segmentation",
                    frame: sandMark.frame, bodyPart: sandMark.bodyPart)
                signed = markIntoPit
            } else {
                warnings.append("sand_mark_far_behind_heel")
            }
        }
        return (landing, signed, markIntoPit)
    }

    /// distance._landing_warnings.
    static func landingWarnings(
        signedIntoPit: Double, landingWorld: SIMD2<Double>, _ homography: PitHomography, warnings: inout [String]
    ) {
        if signedIntoPit < 0 { warnings.append("landing_before_pit_edge") }
        let (low, high) = homography.xRange
        if !(low - outsideMarginM <= landingWorld.x && landingWorld.x <= high + outsideMarginM) {
            warnings.append("landing_outside_calibration")
        }
        if homography.rmsM > calibrationRmsWarnM { warnings.append("calibration_inconsistent") }
    }

    /// distance._actual_distance: (actual distance, take-off toe to pit edge).
    static func actualDistance(
        takeoffWorld: SIMD2<Double>?, landingWorld: SIMD2<Double>, nearEnd: Double,
        _ homography: PitHomography, warnings: inout [String]
    ) -> (actual: Double?, toeToPitEdge: Double?) {
        var actual: Double?
        var toeToPitEdge: Double?
        if let takeoffWorld {
            let edge = Swift.abs(takeoffWorld.x - nearEnd)
            toeToPitEdge = edge
            let offset = homography.calibration.boardOffsetM
            if offset - toeCheckBeforeM <= edge && edge <= offset + toeCheckBehindM {
                actual = PyRound.numpy(Swift.abs(landingWorld.x - takeoffWorld.x), 3)
            } else {
                warnings.append("takeoff_toe_off_board")
            }
        }
        return (actual, toeToPitEdge)
    }

    private static func round1(_ v: Double) -> JSONValue { .double(PyRound.python(v, 1)) }
    private static func round3(_ v: Double) -> JSONValue { .double(PyRound.python(v, 3)) }

    /// distance._distance_record.
    static func distanceRecord(
        landing: Landing, intoPit: Double, markIntoPit: Double?, takeoffWorld: SIMD2<Double>?,
        takeoffName: String?, toeToPitEdge: Double?, actual: Double?, nearEnd: Double,
        _ homography: PitHomography
    ) -> JSONValue {
        let offset = homography.calibration.boardOffsetM
        return .object([
            "official_m": round3(intoPit + offset),
            "actual_m": JSONValue(actual),
            "takeoff_toe_to_pit_edge_m": toeToPitEdge.map(round3) ?? .null,
            "landing_into_pit_m": round3(intoPit),
            "board_offset_m": .double(offset),
            "landing_point": .object([
                "joint": .string(landing.name),
                "score": round3(landing.score),
                "source": .string(landing.source),
                "body_part": JSONValue(landing.bodyPart),
                "frame": .int(landing.frame),
                "image_px": .array([round1(landing.px.x), round1(landing.px.y)]),
                "world_m": .array([round3(landing.world.x), round3(landing.world.y)]),
            ]),
            "sand_mark_into_pit_m": markIntoPit.map(round3) ?? .null,
            "takeoff_toe": takeoffWorld.map { world in
                JSONValue.object([
                    "joint": JSONValue(takeoffName),
                    "world_m": .array([round3(world.x), round3(world.y)]),
                ])
            } ?? .null,
            "pit_near_end_x_m": .double(nearEnd),
            "calibration_rms_m": .double(PyRound.python(homography.rmsM, 4)),
        ])
    }

    /// distance.measure_distance: (distance record or nil, warnings).
    public static func measureDistance(
        track: PoseTrack, events: JumpEvents, homography: PitHomography, sandMark: SandMark? = nil
    ) -> (distance: JSONValue?, warnings: [String]) {
        var warnings: [String] = []
        let byFrame = track.indexByFrame()
        let toeIndex = events.toeOff.flatMap { byFrame[$0] }
        guard let sandLanding = events.sandLanding, let landIndex = byFrame[sandLanding] else {
            return (nil, ["no_sand_landing"])
        }

        var takeoffWorld: SIMD2<Double>?
        var takeoffName: String?
        if let toeIndex {
            (takeoffWorld, takeoffName) = takeoffToeWorld(track, events, toeIndex: toeIndex, homography)
        }
        var nearEnd: Double?
        if let takeoffWorld {
            let (low, high) = homography.xRange
            nearEnd = Swift.abs(high - takeoffWorld.x) < Swift.abs(low - takeoffWorld.x) ? high : low
        } else {
            takeoffName = nil
            warnings.append("no_takeoff_toe")
        }

        let heels = landingHeels(track, landIndex: landIndex, homography)
        if heels.isEmpty { return (nil, warnings + ["no_landing_heel"]) }
        let near = nearEnd ?? PitHomography.nearEndFromDirection(homography, runSide: track.pitSide())
        var landing = nearestHeel(heels, nearEnd: near, frame: sandLanding)
        var (signed, direction) = signedIntoPit(landing.world, nearEnd: near, homography)
        var markIntoPit: Double?
        if let sandMark {
            let preferred = preferSandMark(
                landing: landing, signedIntoPit: signed, sandMark: sandMark, homography,
                nearEnd: near, direction: direction, warnings: &warnings)
            landing = preferred.landing
            signed = preferred.signedIntoPit
            markIntoPit = preferred.markIntoPit
        }
        landingWarnings(signedIntoPit: signed, landingWorld: landing.world, homography, warnings: &warnings)
        let (actual, toeToPitEdge) = actualDistance(
            takeoffWorld: takeoffWorld, landingWorld: landing.world, nearEnd: near, homography, warnings: &warnings)
        let record = distanceRecord(
            landing: landing, intoPit: Swift.max(0.0, signed), markIntoPit: markIntoPit,
            takeoffWorld: takeoffWorld, takeoffName: takeoffName, toeToPitEdge: toeToPitEdge,
            actual: actual, nearEnd: near, homography)
        _ = direction
        return (record, warnings)
    }
}
