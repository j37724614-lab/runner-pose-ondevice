import Foundation

/// One ground contact of a foot (approach.foot_contacts' dict).
public struct FootContact: Sendable, Equatable {
    public var foot: Side
    public var index: Int
    public var frame: Int
    public var startIndex: Int
    public var startFrame: Int
    public var timeS: Double
    public var imagePx: SIMD2<Double>

    public var json: JSONValue {
        .object([
            "foot": .string(foot.rawValue),
            "index": .int(index),
            "frame": .int(frame),
            "start_index": .int(startIndex),
            "start_frame": .int(startFrame),
            "time_s": .double(timeS),
            "image_px": .array([.double(imagePx.x), .double(imagePx.y)]),
        ])
    }
}

/// Approach run: foot contacts before the take-off and the last strides (approach.py).
public enum Approach {
    /// Body heights/s: "foot still", the same level as the toe-off rule.
    public static let stanceSpeed = 1.15
    public static let minStanceFrames = 2
    /// Last 4 contacts before the line = 3 strides.
    public static let approachContacts = 4

    /// approach.foot_contacts: runs where the toe centre is still, at the run's middle frame.
    public static func footContacts(_ track: PoseTrack) -> [FootContact] {
        var contacts: [FootContact] = []
        for side in [Side.left, Side.right] {
            let still = track.toeCenterSpeed2DPerS(side).map { $0 < stanceSpeed }
            for run in Runs.trueRuns(still, minLength: minStanceFrames) {
                let start = run.lowerBound, end = run.upperBound
                let index = (start + end - 1) / 2
                guard let point = DistanceMeasurement.footPoint(track, index: index, side: side, kind: .toe).point else {
                    continue
                }
                contacts.append(
                    FootContact(
                        foot: side, index: index, frame: track.frames[index], startIndex: start,
                        startFrame: track.frames[start],
                        timeS: PyRound.numpy(Double(track.frames[index]) / track.fps, 4), imagePx: point))
            }
        }
        // sorted(..., key=index) is stable
        return contacts.enumerated().sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }
            .map(\.element)
    }

    /// approach._add_approach_points: records the approach contacts before the board (contact frame
    /// and toe point) in `result` (`_takeoff_step`, `_landing_point`, `_approach_contacts`).
    static func addApproachPoints(_ result: inout JSONObject, track: PoseTrack, events: JumpEvents, side: Side) {
        let byFrame = track.indexByFrame()
        guard let boardContact = events.boardContact, let boardIndex = byFrame[boardContact] else { return }
        if let foot = track.takeoffFoot(events),
           let point = DistanceMeasurement.footPoint(track, index: boardIndex, side: foot, kind: .toe).point
        {
            result["_takeoff_step"] = .object([
                "foot": .string(foot.rawValue),
                "frame": .int(boardContact),
                "image_px": .array([.double(point.x), .double(point.y)]),
            ])
        }
        if let sandLanding = events.sandLanding, let landIndex = byFrame[sandLanding] {
            var heels: [(point: SIMD2<Double>, name: String, score: Double)] = []
            for footSide in [Side.left, Side.right] {
                let (p, n, s) = DistanceMeasurement.footPoint(track, index: landIndex, side: footSide, kind: .heel)
                if let p { heels.append((p, n, s)) }
            }
            if var best = heels.first {
                // running toward the left: the heel nearest the board has the larger x (first wins ties)
                for h in heels.dropFirst() {
                    if side == .left ? h.point.x > best.point.x : h.point.x < best.point.x { best = h }
                }
                result["_landing_point"] = .object([
                    "joint": .string(best.name),
                    "score": .double(best.score),
                    "frame": .int(sandLanding),
                    "image_px": .array([.double(best.point.x), .double(best.point.y)]),
                ])
            }
        }
        result["_approach_contacts"] = .array(
            footContacts(track).filter { $0.startIndex < boardIndex - 2 }.map {
                .object([
                    "foot": .string($0.foot.rawValue),
                    "frame": .int($0.startFrame),
                    "image_px": .array([.double($0.imagePx.x), .double($0.imagePx.y)]),
                ])
            })
    }

    /// approach.approach_profile: the last approach contacts as metres from the take-off line
    /// (negative = before it), strides and speed.
    public static func approachProfile(_ result: JSONObject, homography: PitHomography, fps: Double) -> JSONValue? {
        let distance = result["distance"]?.objectValue ?? JSONObject()
        guard let nearEnd = distance["pit_near_end_x_m"]?.doubleValue else { return nil }
        let farEnd = nearEnd == homography.xRange.0 ? homography.xRange.1 : homography.xRange.0
        let direction = farEnd > nearEnd ? 1.0 : -1.0
        let offset = homography.calibration.boardOffsetM

        func point(_ value: JSONValue?) -> SIMD2<Double> {
            let xs = (value?.arrayValue ?? []).map { $0.doubleValue ?? .nan }
            return SIMD2(xs[0], xs[1])
        }
        func fromLine(_ imagePx: SIMD2<Double>) -> Double {
            (homography.toWorld(imagePx).x - nearEnd) * direction + offset
        }

        var contacts: [JSONValue] = result["_approach_contacts"]?.arrayValue ?? []
        let takeoffStep = result["_takeoff_step"]
        if let step = takeoffStep, !(step.objectValue?.isEmpty ?? true) { contacts.append(step) }
        contacts = contacts.enumerated().sorted {
            ($0.element["frame"]?.intValue ?? 0, $0.offset) < ($1.element["frame"]?.intValue ?? 0, $1.offset)
        }.map(\.element)
        contacts = Array(contacts.suffix(approachContacts))
        if contacts.isEmpty { return nil }
        let xs = contacts.map { fromLine(point($0["image_px"])) }
        let strides: [JSONValue] = zip(xs, xs.dropFirst()).map { .double(PyRound.python($1 - $0, 3)) }
        let firstFrame = contacts[0]["frame"]?.intValue ?? 0
        let lastFrame = contacts[contacts.count - 1]["frame"]?.intValue ?? 0
        let elapsed = Double(lastFrame - firstFrame) / fps
        var speed: JSONValue = .null
        if elapsed > 0 && xs[xs.count - 1] > xs[0] {
            speed = .double(PyRound.numpy((xs[xs.count - 1] - xs[0]) / elapsed, 3))
        }
        let hasStep = takeoffStep.map { !($0.objectValue?.isEmpty ?? true) } ?? false
        return .object([
            "contacts": .array(
                zip(contacts, xs).map { c, x in
                    .object([
                        "frame": c["frame"] ?? .null,
                        "foot": c["foot"] ?? .null,
                        "from_line_m": .double(PyRound.python(x, 3)),
                    ])
                }),
            "stride_lengths_m": .array(strides),
            "speed_mps": speed,
            "takeoff_from_line_m": hasStep ? .double(PyRound.python(xs[xs.count - 1], 3)) : .null,
        ])
    }
}
