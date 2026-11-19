import Foundation

/// Failed attempt (no take-off): why there was no jump (failed_attempt.py; the line-crossing
/// check image is not ported).
public enum FailedAttempt {

    /// failed_attempt.airborne_profile: (longest airborne run in seconds, highest bbox-bottom rise
    /// in body heights) -- find_flight's test.
    public static func airborneProfile(_ track: PoseTrack) -> (longestAirborneS: Double, maxRise: Double) {
        let rule = FlightRule()
        let reach = Swift.max(1, PyRound.toInt(rule.groundReachS * track.fps))
        let bottomY = track.bottomY
        let heights = track.boxHeights
        var rise = [Double](repeating: .nan, count: track.count)
        for index in 0..<rise.count {
            if let ground = Runs.localGroundY(bottomY, index: index, reach: reach) {
                rise[index] = (ground - bottomY[index]) / heights[index]
            }
        }
        let runs = Runs.trueRuns(rise.map { $0 > rule.riseRatio }, minLength: 1)
        let longest = runs.map { $0.count }.max() ?? 0
        let maxRise = rise.contains(where: { $0.isFinite }) ? NP.nanMax(rise) : 0.0
        return (Double(longest) / track.fps, maxRise)
    }

    /// failed_attempt.analyse_failed_attempt: line crossing, last step before the take-off line,
    /// approach speed, airborne time.
    public static func analyseFailedAttempt(
        track: PoseTrack, homography: PitHomography?, boardOffsetM: Double,
        takeoffLine: TakeoffLine? = nil, runSide: Side = .left
    ) -> JSONValue {
        let (longest, maxRise) = airborneProfile(track)
        let contacts = Approach.footContacts(track)
        var failure = JSONObject()
        failure["longest_airborne_s"] = .double(PyRound.python(longest, 3))
        failure["required_airborne_s"] = .double(FlightRule().minFlightS)
        failure["max_rise_body_heights"] = .double(PyRound.python(maxRise, 3))
        failure["takeoff_line_source"] = .null
        failure["line_crossing"] = .null
        failure["last_contact_before_line"] = .null
        failure["first_contact_past_line"] = .null
        failure["contacts_past_line"] = .null
        failure["approach_speed_mps"] = .null
        failure["approach_stride_lengths_m"] = .array([])

        let beforeLine: (SIMD2<Double>) -> Double
        if let homography {
            let nearEnd = PitHomography.nearEndFromDirection(homography, runSide: runSide)
            let outward = nearEnd >= (homography.xRange.0 + homography.xRange.1) / 2 ? 1.0 : -1.0
            let lineX = nearEnd + outward * boardOffsetM
            // metres still before the line (negative = past it)
            beforeLine = { (homography.toWorld($0).x - lineX) * outward }
            failure["takeoff_line_source"] = .string("pit_calibration")
            failure["_line_world_x"] = .double(lineX)
        } else if let takeoffLine {
            // pixels; no metres without a calibration
            beforeLine = { point in
                let gap = point.x - takeoffLine.x(atY: point.y)
                return runSide == .left ? gap : -gap
            }
            failure["takeoff_line_source"] = .string("board")
        } else {
            return .object(failure)
        }

        for index in 0..<track.count {
            let crossed = [Side.left, Side.right].contains { side in
                guard let p = DistanceMeasurement.footPoint(track, index: index, side: side, kind: .toe).point else {
                    return false
                }
                return beforeLine(p) < 0
            }
            if crossed {
                failure["line_crossing"] = DistanceMeasurement.event(track, frame: track.frames[index])
                break
            }
        }

        let inMetres = homography != nil
        let toLine = contacts.map { beforeLine($0.imagePx) }
        let beforeIdx = contacts.indices.filter { toLine[$0] >= 0 }
        let pastIdx = contacts.indices.filter { toLine[$0] < 0 }
        let unit = inMetres ? "m" : "px"

        func describe(_ i: Int, _ key: String) -> JSONValue {
            .object([
                "frame": .int(contacts[i].frame),
                "time_s": .double(contacts[i].timeS),
                "foot": .string(contacts[i].foot.rawValue),
                "\(key)_\(unit)": .double(PyRound.python(Swift.abs(toLine[i]), inMetres ? 3 : 1)),
            ])
        }
        if let last = beforeIdx.last { failure["last_contact_before_line"] = describe(last, "distance_to_line") }
        if let first = pastIdx.first { failure["first_contact_past_line"] = describe(first, "distance_past_line") }
        failure["contacts_past_line"] = .int(pastIdx.count)

        if let homography, beforeIdx.count >= 2 {
            let approach = Array(beforeIdx.suffix(Approach.approachContacts))
            let xs = approach.map { homography.toWorld(contacts[$0].imagePx).x }
            failure["approach_stride_lengths_m"] = .array(
                zip(xs, xs.dropFirst()).map { .double(PyRound.numpy(Swift.abs($1 - $0), 3)) })
            let elapsed = Double(contacts[approach[approach.count - 1]].frame - contacts[approach[0]].frame) / track.fps
            if elapsed > 0 {
                failure["approach_speed_mps"] = .double(
                    PyRound.numpy(Swift.abs(xs[xs.count - 1] - xs[0]) / elapsed, 3))
            }
        }
        failure["_contacts"] = .array(
            contacts.indices.map { i in
                .object([
                    "frame": .int(contacts[i].frame),
                    "image_px": .array([.double(contacts[i].imagePx.x), .double(contacts[i].imagePx.y)]),
                    "past_line": .bool(toLine[i] < 0),
                ])
            })
        if inMetres {  // for the review diagram: metres from the take-off line, negative = before it
            failure["contacts"] = .array(
                contacts.indices.map { i in
                    .object([
                        "frame": .int(contacts[i].frame),
                        "foot": .string(contacts[i].foot.rawValue),
                        "from_line_m": .double(PyRound.python(-toLine[i], 3)),
                    ])
                })
        }
        return .object(failure)
    }
}
