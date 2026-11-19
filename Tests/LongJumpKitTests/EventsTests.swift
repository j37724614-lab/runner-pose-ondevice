import XCTest
@testable import LongJumpKit

/// Pose-only event detection replayed against every recorded server call.
final class EventsTests: XCTestCase {

    private func checkBoardRule(_ v: JSONValue, _ c: String) {
        let r = BoardContactRule()
        XCTAssertEqual(v["max_still_speed_per_s"]?.fixtureDouble, r.maxStillSpeedPerS, c)
        XCTAssertEqual(v["toe_off_max_still_speed_per_s"]?.fixtureDouble, r.toeOffMaxStillSpeedPerS, c)
        XCTAssertEqual(v["max_bridge_frames"]?.intValue, r.maxBridgeFrames, c)
        XCTAssertEqual(v["speed_smoothing"]?.intValue, r.speedSmoothing, c)
        XCTAssertEqual(v["max_gap_before_flight"]?.intValue, r.maxGapBeforeFlight, c)
        XCTAssertEqual(v["max_frames_back"]?.intValue, r.maxFramesBack, c)
        XCTAssertEqual(v["adaptive_td_ratio"]?.fixtureDouble, r.adaptiveTdRatio, c)
        XCTAssertEqual(v["adaptive_td_max_disagreement_frames"]?.intValue, r.adaptiveTdMaxDisagreementFrames, c)
        XCTAssertEqual(v["adaptive_valley_lookback_frames"]?.intValue, r.adaptiveValleyLookbackFrames, c)
        XCTAssertEqual(v["adaptive_reference_lookback_frames"]?.intValue, r.adaptiveReferenceLookbackFrames, c)
        XCTAssertEqual(v["adaptive_reference_percentile"]?.fixtureDouble, r.adaptiveReferencePercentile, c)
        XCTAssertEqual(v["adaptive_floor_samples"]?.intValue, r.adaptiveFloorSamples, c)
        XCTAssertEqual(v["fixed_td_min_reference_ratio"]?.fixtureDouble, r.fixedTdMinReferenceRatio, c)
        XCTAssertEqual(v["fixed_td_max_precontact_below_fraction"]?.fixtureDouble, r.fixedTdMaxPrecontactBelowFraction, c)
    }

    private func checkSandRule(_ v: JSONValue, _ c: String) {
        let r = SandLandingRule()
        XCTAssertEqual(v["smoothing"]?.intValue, r.smoothing, c)
        XCTAssertEqual(v["deceleration_smoothing"]?.intValue, r.decelerationSmoothing, c)
        XCTAssertEqual(v["descent_search_after_flight"]?.intValue, r.descentSearchAfterFlight, c)
        XCTAssertEqual(v["search_before_flight_end"]?.intValue, r.searchBeforeFlightEnd, c)
        XCTAssertEqual(v["still_speed_heights_per_s"]?.fixtureDouble, r.stillSpeedHeightsPerS, c)
        XCTAssertEqual(v["still_frames"]?.intValue, r.stillFrames, c)
        XCTAssertEqual(v["max_after_flight_s"]?.fixtureDouble, r.maxAfterFlightS, c)
    }

    private func checkTrimRule(_ v: JSONValue, _ c: String) {
        let r = TrimRule()
        XCTAssertEqual(v["coarse_percentile"]?.fixtureDouble, r.coarsePercentile, c)
        XCTAssertEqual(v["fast_ratio"]?.fixtureDouble, r.fastRatio, c)
        XCTAssertEqual(v["slow_ratio"]?.fixtureDouble, r.slowRatio, c)
        XCTAssertEqual(v["slow_hold"]?.intValue, r.slowHold, c)
        XCTAssertEqual(v["settle_window"]?.intValue, r.settleWindow, c)
        XCTAssertEqual(v["rise_ratio"]?.fixtureDouble, r.riseRatio, c)
        XCTAssertEqual(v["rise_hold"]?.intValue, r.riseHold, c)
        XCTAssertEqual(v["speed_smoothing"]?.intValue, r.speedSmoothing, c)
        XCTAssertEqual(v["height_smoothing"]?.intValue, r.heightSmoothing, c)
    }

    private func replay(_ name: String, expected: Int, _ body: (LongJumpCase, RecordedCall) throws -> Void) throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls(name) {
                try body(c, call)
                n += 1
            }
        }
        print("replayed \(n) \(name) calls")
        XCTAssertEqual(n, expected, name)
    }

    func testTrimEnd() throws {
        try replay("find_trim_end", expected: 33) { c, call in
            checkTrimRule(try call.arg("rule"), c.name)
            let r = JumpEventDetection.findTrimEnd(try c.track(call.arg("track")))
            XCTAssertEqual(r.endIndex, call.result["end_index"]?.intValue, c.name)
            XCTAssertEqual(r.fastSegment, call.result["fast_segment"]?.range, c.name)
            XCTAssertEqual(r.anchorIndex, call.result["anchor_index"]?.intValue, c.name)
            let ref = call.result["reference_speed"]?.fixtureDouble
            XCTAssertEqual(r.referenceSpeed?.bitPattern, ref?.bitPattern, c.name)
        }
    }

    func testFlight() throws {
        try replay("find_flight", expected: 33) { c, call in
            let rule = try call.arg("rule")
            XCTAssertEqual(rule["min_flight_s"]?.fixtureDouble, FlightRule().minFlightS)
            XCTAssertEqual(rule["rise_ratio"]?.fixtureDouble, FlightRule().riseRatio)
            XCTAssertEqual(rule["ground_reach_s"]?.fixtureDouble, FlightRule().groundReachS)
            XCTAssertEqual(JumpEventDetection.findFlight(try c.track(call.arg("track"))), call.result.range, c.name)
        }
        try replay("flight_apex", expected: 60) { c, call in
            let flight = try XCTUnwrap(call.arg("flight").range)
            XCTAssertEqual(
                JumpEventDetection.flightApex(bottomY: try call.arg("bottom_y").doubles, flight: flight),
                call.result.intValue, c.name)
        }
    }

    func testSandLanding() throws {
        try replay("find_sand_landing", expected: 30) { c, call in
            checkSandRule(try call.arg("rule"), c.name)
            let got = JumpEventDetection.findSandLanding(
                bottomY: try call.arg("bottom_y").doubles, flight: try XCTUnwrap(call.arg("flight").range),
                boxHeights: try call.arg("box_heights").doubles, fps: try XCTUnwrap(call.arg("fps").fixtureDouble))
            XCTAssertEqual(got, call.result.intValue, c.name)
        }
        try replay("review_sand_landing", expected: 30) { c, call in
            checkSandRule(try call.arg("rule"), c.name)
            let got = JumpEventDetection.reviewSandLanding(
                try call.arg("sand_index").intValue, flight: try XCTUnwrap(call.arg("flight").range),
                fps: try XCTUnwrap(call.arg("fps").fixtureDouble))
            XCTAssertEqual(got, call.result.arrayValue?.compactMap(\.stringValue), c.name)
        }
    }

    func testBoardContactFromSpeed() throws {
        try replay("_support_run_from_speed", expected: 76) { c, call in
            checkBoardRule(try call.arg("rule"), c.name)
            let got = JumpEventDetection.supportRunFromSpeed(
                try call.arg("speed").doubles, flightStart: try XCTUnwrap(call.arg("flight_start").intValue),
                threshold: try XCTUnwrap(call.arg("threshold").fixtureDouble), rule: BoardContactRule())
            let expected = call.result.ints
            XCTAssertEqual(got.map { [$0.start, $0.end] } ?? [], expected, c.name)
        }
        try replay("_adaptive_board_contact_from_speed", expected: 38) { c, call in
            checkBoardRule(try call.arg("rule"), c.name)
            let got = JumpEventDetection.adaptiveBoardContactFromSpeed(
                try call.arg("speed").doubles, flightStart: try XCTUnwrap(call.arg("flight_start").intValue),
                rule: BoardContactRule())
            XCTAssertEqual(got, call.result.intValue, c.name)
        }
        try replay("_select_board_contact_from_speed", expected: 38) { c, call in
            checkBoardRule(try call.arg("rule"), c.name)
            let scale = try call.arg("scale_speed")
            let got = JumpEventDetection.selectBoardContactFromSpeed(
                try call.arg("speed").doubles, flightStart: try XCTUnwrap(call.arg("flight_start").intValue),
                scaleSpeed: scale.isNull ? nil : scale.doubles)
            XCTAssertEqual(got.index, call.result["index"]?.intValue, c.name)
            XCTAssertEqual(got.mode, call.result["mode"]?.stringValue, c.name)
            XCTAssertEqual(got.referenceSpeed?.bitPattern, call.result["reference_speed"]?.fixtureDouble?.bitPattern, c.name)
            XCTAssertEqual(
                got.precontactBelowFixedFraction?.bitPattern,
                call.result["precontact_below_fixed_fraction"]?.fixtureDouble?.bitPattern, c.name)
        }
    }

    func testBoardContactAndToeOff() throws {
        try replay("find_board_contact", expected: 30) { c, call in
            checkBoardRule(try call.arg("rule"), c.name)
            let got = JumpEventDetection.findBoardContact(
                try c.track(call.arg("track")), flightStart: try XCTUnwrap(call.arg("flight_start").intValue))
            XCTAssertEqual(got, call.result.intValue, c.name)
        }
        try replay("find_toe_off", expected: 30) { c, call in
            checkBoardRule(try call.arg("rule"), c.name)
            let got = JumpEventDetection.findToeOff(
                try c.track(call.arg("track")), boardContact: try call.arg("board_contact").intValue,
                flightStart: try call.arg("flight_start").intValue)
            XCTAssertEqual(got, call.result.intValue, c.name)
        }
    }
}
