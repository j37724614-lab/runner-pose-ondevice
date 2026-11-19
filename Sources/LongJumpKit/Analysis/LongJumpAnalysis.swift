import Foundation

/// The whole long-jump analysis of one attempt: analysis.analyse_long_jump of the server.
///
/// Input is the pose of the camera that films board and pit (the pipeline's
/// `pose/keypoints_2d.json`), its first video frame (board detection), the pit calibration the
/// user marked (distance) and, optionally, a runner segmenter (nearest sand mark).  The result is
/// the server's result document with the same keys; internal keys start with "_" (drawing data
/// for the review overlay) and `publicResult` drops them, as long_jump_result.json does.
///
/// Differences from the server, all outside the numbers:
/// - a pose-file error reads "pose: <reason>" without the file path;
/// - there is no sand-mark cache (the phone segments once per analysis anyway);
/// - the check images (landing_check.jpg, takeoff_check.jpg) are not drawn.
public enum LongJumpAnalysis {
    /// analysis.MIN_TRACK_FRAMES
    public static let minTrackFrames = 10

    /// Analyse one attempt from a keypoints_2d.json document.
    ///
    /// - Parameters:
    ///   - cameraIndex: the pit camera (nil = the last camera in the document).
    ///   - firstFrame: the video's first frame; nil when there is no video (then no board check
    ///     and no sand mark, as on the server).
    ///   - pit: the pit calibration; nil = no distance.
    ///   - sandMarks: runner masks for the sand-mark search; nil while a video exists =
    ///     "segmentation_unavailable" (the heel distance still stands).
    public static func analyse(
        keypointsJSON: Data,
        cameraIndex: Int? = nil,
        firstFrame: PixelImage? = nil,
        pit: PitCalibration? = nil,
        sandMarks: RunnerMaskSource? = nil
    ) -> JSONObject {
        let full: PoseTrack
        do {
            full = try PoseTrack.load(keypointsJSON: keypointsJSON, cameraIndex: cameraIndex)
        } catch {
            return trackingLost("pose: \(error)")
        }
        return analyse(fullTrack: full, cameraIndex: cameraIndex, firstFrame: firstFrame, pit: pit, sandMarks: sandMarks)
    }

    /// Analyse one attempt from its (untrimmed) pose track.
    public static func analyse(
        fullTrack full: PoseTrack,
        cameraIndex: Int?,
        firstFrame: PixelImage? = nil,
        pit: PitCalibration? = nil,
        sandMarks: RunnerMaskSource? = nil
    ) -> JSONObject {
        if full.count < minTrackFrames { return trackingLost("too_few_pose_frames") }
        let span = full.timestamps[full.count - 1] - full.timestamps[0]
        if !span.isFinite || span <= 0 { return trackingLost("invalid_timestamps") }

        let trim = JumpEventDetection.findTrimEnd(full)
        let track = full.until(trim.endIndex)
        let side = track.pitSide()
        var board: BoardView?
        if let firstFrame, let mask = BoardDetector.detectBoard(firstFrame).mask {
            board = BoardView(mask: mask, line: BoardDetector.fitTakeoffLine(mask, pitSide: side))
        }
        var takeoffLine = board?.line
        let events = JumpEventDetection.detectJumpEvents(track, board: board, pitSide: side)

        var result = JSONObject()
        result["status"] = .string((events == nil ? LongJumpStatus.noTakeoff : .jump).rawValue)
        result["camera_index"] = JSONValue(cameraIndex)
        result["fps"] = .double(PyRound.numpy(track.fps, 3))
        result["run_direction"] = .string(side.rawValue)
        result["events"] = .object(JSONObject())
        result["flight_time_s"] = .null
        result["distance"] = .null
        result["warnings"] = .array([])
        var warnings: [String] = []

        guard let events else {
            warnings.append("no_takeoff_run_through")
            let homography = tryHomography(pit, &warnings)
            result["failure"] = FailedAttempt.analyseFailedAttempt(
                track: track, homography: homography,
                boardOffsetM: pit?.boardOffsetM ?? PitCalibration.defaultBoardOffsetM,
                takeoffLine: takeoffLine, runSide: side
            )
            result["warnings"] = .array(warnings.map(JSONValue.string))
            return result
        }

        addEventEntries(&result, full: full, track: track, trim: trim, events: events)
        Approach.addApproachPoints(&result, track: track, events: events, side: side)
        if let toeOff = events.toeOff, let landing = events.sandLanding {
            result["flight_time_s"] = .double(PyRound.numpy(Double(landing - toeOff) / track.fps, 4))
        }
        if pit == nil { warnings.append("no_pit_calibration") }
        let homography = tryHomography(pit, &warnings)

        // take-off board (analysis._assess_board_takeoff)
        var (takeoff, takeoffDraw) = TakeoffCheck.assessTakeoff(
            track: track, events: events, board: board, runSide: side, homography: homography
        )
        if takeoff == nil, let homography, let firstFrame, let pit,
           let foot = track.takeoffFoot(events),
           let boardContact = events.boardContact, let tdIndex = track.indexByFrame()[boardContact],
           let toe = DistanceMeasurement.footPoint(track, index: tdIndex, side: foot, kind: .toe).point,
           let partial = TakeoffCheck.findPartialBoard(
               image: firstFrame, toePx: toe, homography: homography, runSide: side, boardOffsetM: pit.boardOffsetM
           )
        {
            // no whole board: a take-off aid may cover it; the exposed sliver next to the toe
            let assessed = TakeoffCheck.assessPartialTakeoff(track: track, events: events, board: partial, homography: homography)
            (takeoff, takeoffDraw, takeoffLine) = (assessed.check, assessed.draw, assessed.line)
            if takeoff != nil { warnings.append("board_partly_covered") }
        }
        if let takeoff {
            result["takeoff"] = takeoff
            result["_takeoff_draw"] = takeoffDraw ?? .null
            if takeoff["foul"]?.boolValue == true { result["status"] = .string(LongJumpStatus.foul.rawValue) }
            if takeoff["uncertain"]?.boolValue == true { warnings.append("takeoff_near_line") }
        }

        guard let homography, let pit else {
            result["warnings"] = .array(warnings.map(JSONValue.string))
            result["_overlay"] = ResultOutput.overlayData(track: track, events: events, result: result, homography: nil)
            return result
        }

        // nearest sand mark (analysis._locate_sand_mark)
        var mark: SandMark?
        if firstFrame != nil, let landing = events.sandLanding {
            if let sandMarks {
                do {
                    mark = try SandMarkFinder.findSandMark(
                        track: track, sandLandingFrame: landing, runSide: side, masks: sandMarks
                    )
                } catch {
                    warnings.append("sand_mark_failed: \(type(of: error))")
                }
            } else {
                warnings.append("segmentation_unavailable")
            }
        }

        // distance (analysis._finish_with_distance)
        let measured = DistanceMeasurement.measureDistance(track: track, events: events, homography: homography, sandMark: mark)
        result["distance"] = measured.distance ?? .null
        warnings += measured.warnings
        if let takeoffDraw, let takeoffLine, measured.distance != nil {
            result["warnings"] = .array(warnings.map(JSONValue.string))
            TakeoffCheck.checkBoardLineAgainstPit(
                &result, homography: homography, takeoffDraw: takeoffDraw, takeoffLine: takeoffLine, pit: pit
            )
            warnings = (result["warnings"]?.arrayValue ?? []).compactMap(\.stringValue)
        }
        if case .object(var distance) = result["distance"] ?? .null {
            setActualDistanceSource(&distance, takeoff: result["takeoff"])
            result["distance"] = .object(distance)
        }
        result["headline_m"] = result["distance"]?["official_m"] ?? .null
        if let point = result["distance"]?["landing_point"] {
            let frame = point["frame"]?.intValue
            result["_landing_point"] = [
                "joint": point["joint"] ?? .null,
                "score": point["score"] ?? .null,
                "frame": .int((frame != nil && frame != 0) ? frame! : (events.sandLanding ?? 0)),
                "image_px": point["image_px"] ?? .null,
            ]
            result["approach"] = Approach.approachProfile(result, homography: homography, fps: track.fps) ?? .null
        }
        result["warnings"] = .array(warnings.map(JSONValue.string))
        result["_overlay"] = ResultOutput.overlayData(track: track, events: events, result: result, homography: homography)
        return result
    }

    /// The result without internal "_" keys (long_jump_result.json).
    public static func publicResult(_ result: JSONObject) -> JSONObject {
        ResultOutput.publicResult(result)
    }

    // MARK: - Steps of analyse_long_jump

    /// analysis._tracking_lost
    static func trackingLost(_ warning: String) -> JSONObject {
        [
            "status": .string(LongJumpStatus.trackingLost.rawValue),
            "events": .object(JSONObject()),
            "distance": .null,
            "warnings": [.string(warning)],
        ]
    }

    /// analysis._try_pit_homography
    static func tryHomography(_ pit: PitCalibration?, _ warnings: inout [String]) -> PitHomography? {
        guard let pit else { return nil }
        do {
            return try PitHomography(pit)
        } catch {
            warnings.append("pit_calibration: \(error)")
            return nil
        }
    }

    /// analysis._add_event_entries
    static func addEventEntries(_ result: inout JSONObject, full: PoseTrack, track: PoseTrack, trim: TrimResult, events: JumpEvents) {
        result["events"] = [
            "board_contact": DistanceMeasurement.event(track, frame: events.boardContact),
            "toe_off": DistanceMeasurement.event(track, frame: events.toeOff),
            "flight_start": DistanceMeasurement.event(track, frame: events.flightStart),
            "flight_end": DistanceMeasurement.event(track, frame: events.flightEnd),
            "sand_landing": DistanceMeasurement.event(track, frame: events.sandLanding),
        ]
        // end of the attempt (athlete starts getting up in the sand): displays stop here
        if trim.endIndex < full.count {
            result["analysis_end"] = DistanceMeasurement.event(full, frame: full.frames[Swift.max(0, trim.endIndex - 1)])
        }
    }

    /// analysis._set_actual_distance_source: the pit-homography actual distance, replaced by the
    /// board measurement when the take-off check has one.
    static func setActualDistanceSource(_ distance: inout JSONObject, takeoff: JSONValue?) {
        let actual = distance["actual_m"] ?? .null
        distance["actual_m_pit"] = actual
        distance["actual_source"] = actual.isNull ? .null : .string("pit_homography")
        if let takeoff, let check = takeoff.objectValue, !check.isEmpty,
           let toeToLine = check["toe_to_line_m"]?.doubleValue,
           let into = distance["landing_into_pit_m"]?.doubleValue,
           let offset = distance["board_offset_m"]?.doubleValue
        {
            // the take-off toe measured against the board itself, not through the pit homography
            distance["actual_m"] = .double(PyRound.python(into + offset + toeToLine, 3))
            distance["actual_source"] = check["line_source"] ?? .null
        }
    }
}
