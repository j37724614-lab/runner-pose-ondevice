import XCTest
@testable import LongJumpKit

/// Pit homography consumers: distance, approach, failed attempt, take-off check, overlay data,
/// each replayed against every recorded server call.
final class PitAndDistanceTests: XCTestCase {
    static var replayed: [String: Int] = [:]

    private func count(_ name: String) { Self.replayed[name, default: 0] += 1 }

    private func assertJSON(_ actual: JSONValue, _ expected: JSONValue, _ label: String, tolerance: Double = 1e-9) {
        let diffs = jsonDifferences(actual, expected, tolerance: tolerance)
        XCTAssertTrue(diffs.isEmpty, "\(label): \(diffs.prefix(5))")
    }

    func testNearEndFromDirection() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("near_end_from_direction") {
                let h = try XCTUnwrap(homography(fixture: call.args["homography"]))
                let side = try XCTUnwrap(call.arg("run_side").side)
                XCTAssertEqual(PitHomography.nearEndFromDirection(h, runSide: side), call.result.doubleValue, c.name)
                n += 1
            }
        }
        print("REPLAYED near_end_from_direction \(n)")
    }

    func testMeasureDistance() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("measure_distance") {
                let track = try c.track(call.arg("track"))
                let events = try XCTUnwrap(JumpEvents(fixture: call.arg("events")))
                let h = try XCTUnwrap(homography(fixture: call.args["homography"]))
                let mark = call.args["sand_mark"].flatMap { SandMark(fixture: $0) }
                let (distance, warnings) = DistanceMeasurement.measureDistance(
                    track: track, events: events, homography: h, sandMark: mark)
                let expected = try XCTUnwrap(call.result.arrayValue)
                assertJSON(distance ?? .null, expected[0], "\(c.name) distance", tolerance: 0)
                XCTAssertEqual(warnings, expected[1].arrayValue?.compactMap(\.stringValue), c.name)
                n += 1
            }
        }
        print("REPLAYED measure_distance \(n)")
    }

    func testFootContacts() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("foot_contacts") {
                let track = try c.track(call.arg("track"))
                let contacts = Approach.footContacts(track)
                assertJSON(.array(contacts.map(\.json)), call.result, c.name, tolerance: 0)
                n += 1
            }
        }
        print("REPLAYED foot_contacts \(n)")
    }

    func testAddApproachPoints() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("_add_approach_points") {
                let track = try c.track(call.arg("track"))
                let events = try XCTUnwrap(JumpEvents(fixture: call.arg("events")))
                var result = jsonObject(call.args["result"])
                Approach.addApproachPoints(&result, track: track, events: events, side: try XCTUnwrap(call.arg("side").side))
                assertJSON(.object(result), try XCTUnwrap(call.after?["result"]), c.name, tolerance: 0)
                n += 1
            }
        }
        print("REPLAYED _add_approach_points \(n)")
    }

    func testApproachProfile() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("approach_profile") {
                let h = try XCTUnwrap(homography(fixture: call.args["homography"]))
                let profile = Approach.approachProfile(
                    jsonObject(call.args["result"]), homography: h, fps: try XCTUnwrap(call.arg("fps").fixtureDouble))
                assertJSON(profile ?? .null, call.result, c.name, tolerance: 0)
                n += 1
            }
        }
        print("REPLAYED approach_profile \(n)")
    }

    func testAirborneProfile() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("airborne_profile") {
                let (a, b) = FailedAttempt.airborneProfile(try c.track(call.arg("track")))
                assertDoublesEqual([a, b], call.result.doubles, c.name)
                n += 1
            }
        }
        print("REPLAYED airborne_profile \(n)")
    }

    func testAnalyseFailedAttempt() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("analyse_failed_attempt") {
                let h = try homography(fixture: call.args["homography"])
                let line = call.args["takeoff_line"].flatMap { TakeoffLine(fixture: $0) }
                let result = FailedAttempt.analyseFailedAttempt(
                    track: try c.track(call.arg("track")), homography: h,
                    boardOffsetM: try XCTUnwrap(call.arg("board_offset_m").fixtureDouble), takeoffLine: line,
                    runSide: try XCTUnwrap(call.arg("run_side").side))
                assertJSON(result, call.result, c.name, tolerance: 0)
                n += 1
            }
        }
        print("REPLAYED analyse_failed_attempt \(n)")
    }

    func testBoardRowWidth() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("board_row_width_px") {
                let mask = try XCTUnwrap(call.arg("board_mask").mask)
                XCTAssertEqual(BoardDetector.boardRowWidthPx(mask), call.result.doubleValue, c.name)
                n += 1
            }
        }
        print("REPLAYED board_row_width_px \(n)")
    }

    func testAssessTakeoff() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("assess_takeoff") {
                let h = try homography(fixture: call.args["homography"])
                let board = call.args["board"].flatMap { BoardView(fixture: $0) }
                let (check, draw) = TakeoffCheck.assessTakeoff(
                    track: try c.track(call.arg("track")), events: try JumpEvents(fixture: call.arg("events")),
                    board: board, runSide: try XCTUnwrap(call.arg("run_side").side), homography: h)
                let expected = try XCTUnwrap(call.result.arrayValue)
                assertJSON(check ?? .null, expected[0], "\(c.name) check", tolerance: 0)
                assertJSON(draw ?? .null, expected[1], "\(c.name) draw", tolerance: 0)
                n += 1
            }
        }
        print("REPLAYED assess_takeoff \(n)")
    }

    func testAssessPartialTakeoff() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("assess_partial_takeoff") {
                let board = try call.arg("board")
                let h = try XCTUnwrap(homography(fixture: call.args["homography"]))
                let out = TakeoffCheck.assessPartialTakeoff(
                    track: try c.track(call.arg("track")), events: try XCTUnwrap(JumpEvents(fixture: call.arg("events"))),
                    lineWorldX: board["line_world_x"]!.doubleValue!, intoPit: board["into_pit"]!.doubleValue!,
                    edgePx: board["edge_px"]!.point2, bbox: board["bbox"]!.ints, homography: h)
                let expected = try XCTUnwrap(call.result.arrayValue)
                assertJSON(out.check ?? .null, expected[0], "\(c.name) check", tolerance: 0)
                // the line goes through to_image(inv(matrix)): last-bit differences
                assertJSON(out.draw ?? .null, expected[1], "\(c.name) draw", tolerance: 1e-9)
                let line = expected[2].isNull ? nil : TakeoffLine(fixture: expected[2])
                XCTAssertEqual(out.line?.top.x ?? 0, line?.top.x ?? 0, accuracy: 1e-9, c.name)
                XCTAssertEqual(out.line?.bottom.y ?? 0, line?.bottom.y ?? 0, accuracy: 1e-9, c.name)
                n += 1
            }
        }
        print("REPLAYED assess_partial_takeoff \(n)")
    }

    func testCheckBoardLineAgainstPit() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("_check_board_line_against_pit") {
                let h = try XCTUnwrap(homography(fixture: call.args["homography"]))
                var result = jsonObject(call.args["result"])
                TakeoffCheck.checkBoardLineAgainstPit(
                    &result, homography: h, takeoffDraw: try call.arg("takeoff_draw"),
                    takeoffLine: try XCTUnwrap(TakeoffLine(fixture: call.arg("takeoff_line"))),
                    pit: try XCTUnwrap(PitCalibration(fixture: call.arg("pit"))))
                assertJSON(.object(result), try XCTUnwrap(call.after?["result"]), c.name, tolerance: 0)
                n += 1
            }
        }
        print("REPLAYED _check_board_line_against_pit \(n)")
    }

    func testOverlayData() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("overlay_data") {
                let h = try homography(fixture: call.args["homography"])
                let data = ResultOutput.overlayData(
                    track: try c.track(call.arg("track")), events: try XCTUnwrap(JumpEvents(fixture: call.arg("events"))),
                    result: jsonObject(call.args["result"]), homography: h)
                assertJSON(data, call.result, c.name, tolerance: 0)
                n += 1
            }
        }
        print("REPLAYED overlay_data \(n); worst homography world diff \(homographyWorstWorld)")
    }

    func testPublicResult() throws {
        for c in try LongJumpCase.all() {
            let result = jsonObject(try c.result())
            let clean = ResultOutput.publicResult(result)
            XCTAssertFalse(clean.keys.contains { $0.hasPrefix("_") }, c.name)
            if let failure = clean["failure"]?.objectValue {
                XCTAssertFalse(failure.keys.contains { $0.hasPrefix("_") }, c.name)
            }
            XCTAssertEqual(clean.count, result.keys.filter { !$0.hasPrefix("_") }.count, c.name)
        }
    }
}
