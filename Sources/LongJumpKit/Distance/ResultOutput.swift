import Foundation

/// Result vocabulary and output: review-video overlay data and the public result (result_output.py;
/// the image rendering and file writing are not ported).
public enum ResultOutput {

    /// result_output.overlay_data: plain data for the review-video overlay (events, hip trail,
    /// landing mark, measuring tape and the take-off check), in source-frame pixels / frame numbers.
    public static func overlayData(
        track: PoseTrack, events: JumpEvents, result: JSONObject, homography: PitHomography?
    ) -> JSONValue {
        var eventFrames = JSONObject()
        for (name, event) in result["events"]?.objectValue ?? JSONObject() {
            eventFrames[name] = event.objectValue?["frame"] ?? .null
        }
        var data = JSONObject()
        data["status"] = result["status"] ?? .null
        data["fps"] = .double(PyRound.numpy(track.fps, 3))
        data["run_direction"] = result["run_direction"] ?? .null
        data["events"] = .object(eventFrames)
        data["apex"] = .int(events.apex)
        data["end"] = result["analysis_end"]?.objectValue?["frame"] ?? .null
        data["flight_time_s"] = result["flight_time_s"] ?? .null
        data["takeoff"] = result["takeoff"] ?? .null
        data["takeoff_draw"] = result["_takeoff_draw"] ?? .null
        data["official_m"] = result["distance"]?.objectValue?["official_m"] ?? .null
        data["headline_m"] = result["headline_m"] ?? .null
        data["hip_trail"] = .array([])
        data["landing"] = .null
        data["tape"] = .null

        let byFrame = track.indexByFrame()
        let start = byFrame[events.toeOff ?? events.flightStart]
        let end = byFrame[events.sandLanding ?? events.flightEnd]
        if let start, let end, track.jointIndex["left_hip"] != nil {
            var trail: [JSONValue] = []
            if start <= end {
                for i in start...end {
                    let l = DistanceMeasurement.jointPoint(track, "left_hip", i)
                    let r = DistanceMeasurement.jointPoint(track, "right_hip", i)
                    let hx = (l.x + r.x) / 2, hy = (l.y + r.y) / 2
                    if hx.isFinite && hy.isFinite {
                        trail.append(.array([
                            .int(track.frames[i]), .double(PyRound.python(hx, 1)), .double(PyRound.python(hy, 1)),
                        ]))
                    }
                }
            }
            data["hip_trail"] = .array(trail)
        }
        if let distance = result["distance"]?.objectValue, !distance.isEmpty {
            let point = distance["landing_point"]?.objectValue ?? JSONObject()
            data["landing"] = .object([
                "frame": point["frame"] ?? .null,
                "image_px": point["image_px"] ?? .null,
                "source": point["source"] ?? .null,
                "body_part": point["body_part"] ?? .null,
            ])
            if let homography {
                let near = distance["pit_near_end_x_m"]?.doubleValue ?? .nan
                let far = near == homography.xRange.0 ? homography.xRange.1 : homography.xRange.0
                let direction = far > near ? 1.0 : -1.0
                let lineX = near - direction * (distance["board_offset_m"]?.doubleValue ?? .nan)
                let world = point["world_m"]?.arrayValue ?? []
                let yWorld = world[1].doubleValue ?? .nan
                let landX = world[0].doubleValue ?? .nan
                let ends = homography.toImage([SIMD2(lineX, yWorld), SIMD2(landX, yWorld)])
                func r1(_ p: SIMD2<Double>) -> JSONValue {
                    .array([.double(PyRound.python(p.x, 1)), .double(PyRound.python(p.y, 1))])
                }
                var ticks: [JSONValue] = []
                let count = Int(Swift.abs(landX - lineX).rounded(.down))
                if count >= 1 {
                    for metre in 1...count {
                        let x = lineX + direction * Double(metre)
                        let ab = homography.toImage([SIMD2(x, yWorld - 0.12), SIMD2(x, yWorld + 0.12)])
                        ticks.append(.object(["m": .int(metre), "a": r1(ab[0]), "b": r1(ab[1])]))
                    }
                }
                data["tape"] = .object(["start": r1(ends[0]), "end": r1(ends[1]), "ticks": .array(ticks)])
            }
        }
        return .object(data)
    }

    /// result_output.public_result: the result without internal `_` keys (also inside `failure`).
    public static func publicResult(_ result: JSONObject) -> JSONObject {
        var clean = JSONObject()
        for (key, value) in result where !key.hasPrefix("_") { clean[key] = value }
        if case .object(let failure)? = clean["failure"] {
            var filtered = JSONObject()
            for (key, value) in failure where !key.hasPrefix("_") { filtered[key] = value }
            clean["failure"] = .object(filtered)
        }
        return clean
    }
}
