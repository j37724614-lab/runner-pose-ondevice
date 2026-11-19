import XCTest
@testable import LongJumpKit

/// BoardDetector replaying every recorded server call (testdata/longjump/*/calls.json).
final class BoardDetectorTests: XCTestCase {
    private func boardRule(_ v: JSONValue?) -> BoardRule {
        var rule = BoardRule()
        guard let v, !v.isNull else { return rule }
        rule.ringPx = v["ring_px"]!.intValue!
        rule.minArea = v["min_area"]!.intValue!
        rule.maxArea = v["max_area"]!.intValue!
        rule.minRingRed = v["min_ring_red"]!.doubleValue!
        return rule
    }

    private func contactRule(_ v: JSONValue?) -> BoardContactRule {
        var rule = BoardContactRule()
        guard let v, !v.isNull else { return rule }
        rule.maxStillSpeedPerS = v["max_still_speed_per_s"]!.doubleValue!
        rule.toeOffMaxStillSpeedPerS = v["toe_off_max_still_speed_per_s"]!.doubleValue!
        rule.maxBridgeFrames = v["max_bridge_frames"]!.intValue!
        rule.speedSmoothing = v["speed_smoothing"]!.intValue!
        rule.boardDistanceRatio = v["board_distance_ratio"]!.doubleValue!
        rule.maxGapBeforeFlight = v["max_gap_before_flight"]!.intValue!
        rule.maxFramesBack = v["max_frames_back"]!.intValue!
        rule.adaptiveTdRatio = v["adaptive_td_ratio"]!.doubleValue!
        rule.adaptiveTdMaxDisagreementFrames = v["adaptive_td_max_disagreement_frames"]!.intValue!
        rule.adaptiveValleyLookbackFrames = v["adaptive_valley_lookback_frames"]!.intValue!
        rule.adaptiveReferenceLookbackFrames = v["adaptive_reference_lookback_frames"]!.intValue!
        rule.adaptiveReferencePercentile = v["adaptive_reference_percentile"]!.doubleValue!
        rule.adaptiveFloorSamples = v["adaptive_floor_samples"]!.intValue!
        rule.fixedTdMinReferenceRatio = v["fixed_td_min_reference_ratio"]!.doubleValue!
        rule.fixedTdMaxPrecontactBelowFraction = v["fixed_td_max_precontact_below_fraction"]!.doubleValue!
        return rule
    }

    private func checkMask(_ mask: BinaryMask, _ expected: JSONValue, _ label: String) {
        XCTAssertEqual(mask.count, expected["count"]?.intValue, "\(label) count")
        XCTAssertEqual(FNV1a64.rows(mask.data, rowLength: mask.width), expected["$hash"]?.stringValue, "\(label) hash")
    }

    func testMasksAndDetectBoard() throws {
        var red = 0, white = 0, detect = 0
        for c in try LongJumpCase.all() {
            let calls = try c.calls()
            guard calls.contains(where: { ["red_runway_mask", "white_mask", "detect_board"].contains($0.name) }) else { continue }
            let image = try XCTUnwrap(try c.firstFrame(), c.name)
            for call in calls {
                switch call.name {
                case "red_runway_mask":
                    checkMask(BoardDetector.redRunwayMask(image), call.result, "\(c.name) red")
                    red += 1
                case "white_mask":
                    checkMask(BoardDetector.whiteMask(image), call.result, "\(c.name) white")
                    white += 1
                case "detect_board":
                    let result = BoardDetector.detectBoard(image, rule: boardRule(call.args["rule"]))
                    let expected = call.result["candidates"]!.arrayValue!
                    XCTAssertEqual(result.candidates.count, expected.count, "\(c.name) candidates")
                    for (a, e) in zip(result.candidates, expected) {
                        XCTAssertEqual(a.ringRed.bitPattern, e["ring_red"]!.doubleValue!.bitPattern, "\(c.name) ring_red")
                        XCTAssertEqual(a.area, e["area"]!.intValue)
                        XCTAssertEqual(a.label, e["label"]!.intValue)
                        XCTAssertEqual(a.bbox, e["bbox"]!.ints)
                    }
                    let expectedMask = call.result["mask"]?.mask
                    XCTAssertEqual(result.mask == nil, expectedMask == nil, "\(c.name) mask presence")
                    if let m = result.mask, let e = expectedMask { XCTAssertEqual(m, e, "\(c.name) mask") }
                    detect += 1
                default: break
                }
            }
        }
        print("replayed red_runway_mask \(red), white_mask \(white), detect_board \(detect)")
        XCTAssertEqual(red, 33)
        XCTAssertEqual(white, 34)
        XCTAssertEqual(detect, 33)
    }

    func testFitTakeoffLine() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("fit_takeoff_line") {
                let mask = try XCTUnwrap(call.args["board_mask"]?.mask)
                let side = try XCTUnwrap(call.args["pit_side"]?.side)
                let line = BoardDetector.fitTakeoffLine(mask, pitSide: side)
                let expected = try XCTUnwrap(TakeoffLine(fixture: call.result))
                XCTAssertEqual(line, expected, c.name)
                n += 1
            }
        }
        print("replayed fit_takeoff_line \(n)")
        XCTAssertEqual(n, 4)
    }

    func testBoardRowWidth() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("board_row_width_px") {
                let mask = try XCTUnwrap(call.args["board_mask"]?.mask)
                let width = BoardDetector.boardRowWidthPx(mask)
                XCTAssertEqual(width, call.result.doubleValue, c.name)
                n += 1
            }
        }
        print("replayed board_row_width_px \(n)")
        XCTAssertEqual(n, 4)
    }

    func testFindBoardContactWithBoard() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("find_board_contact_with_board") {
                let track = try c.track(call.arg("track"))
                let mask = try XCTUnwrap(call.args["board_mask"]?.mask)
                let line = call.args["takeoff_line"].flatMap { TakeoffLine(fixture: $0) }
                let side = call.args["pit_side"]?.side ?? .left
                let result = BoardDetector.findBoardContactWithBoard(
                    track: track, flightStart: try XCTUnwrap(call.arg("flight_start").intValue),
                    boardMask: mask, takeoffLine: line, pitSide: side, rule: contactRule(call.args["rule"])
                )
                let expected = try XCTUnwrap(BoardContactAssessment(fixture: call.result))
                XCTAssertEqual(result, expected, c.name)
                n += 1
            }
        }
        print("replayed find_board_contact_with_board \(n)")
        XCTAssertEqual(n, 4)
    }

    /// Release-mode timing of detect_board on a 4K frame (printed; run with -c release).
    func testDetectBoardTiming() throws {
        guard let c = try LongJumpCase.all().first(where: { $0.name.hasPrefix("gt_") }),
              let image = try c.firstFrame() else { throw XCTSkip("no 4K frame") }
        let start = Date()
        let runs = 3
        for _ in 0..<runs { _ = BoardDetector.detectBoard(image) }
        print("detect_board \(image.width)x\(image.height): \(Date().timeIntervalSince(start) / Double(runs) * 1000) ms")
    }
}
