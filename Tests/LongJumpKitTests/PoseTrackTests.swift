import XCTest
@testable import LongJumpKit

/// PoseTrack loading and its derived signals against the server, on every recorded attempt.
final class PoseTrackTests: XCTestCase {

    func testTrackLoadsLikeTheServer() throws {
        for c in try LongJumpCase.all() {
            let call = try XCTUnwrap(c.calls("load_pose_track_from_keypoints").first, c.name)
            let track = try c.fullTrack()
            XCTAssertEqual(track.count, call.result["$track"]?.intValue, c.name)
            XCTAssertEqual(track.count, c.document["signals"]?["full"]?["length"]?.intValue, c.name)
        }
    }

    func testSignalsMatchTheServer() throws {
        for c in try LongJumpCase.all() {
            let full = try c.fullTrack()
            for (key, track) in [("full", full), ("trimmed", nil as PoseTrack?)] {
                guard let signals = c.document["signals"]?[key] else { continue }
                let t = track ?? full.until(signals["length"]!.intValue!)
                let label = "\(c.name) \(key)"
                XCTAssertEqual(t.fps, signals["fps"]!.fixtureDouble!, label)
                assertDoublesEqual(t.bottomY, signals["bottom_y"]!.doubles, "\(label) bottom_y")
                assertDoublesEqual(t.boxHeights, signals["box_heights"]!.doubles, "\(label) box_heights")
                assertDoublesEqual(t.hipSpeedTowardPit(), signals["hip_speed_toward_pit"]!.doubles, "\(label) hip speed")
                assertDoublesEqual(t.slowestFootSpeed(), signals["slowest_foot_speed"]!.doubles, "\(label) slowest foot")
                assertDoublesEqual(t.toeCenterSpeed2DPerS(.left), signals["toe_speed_left"]!.doubles, "\(label) toe left")
                assertDoublesEqual(t.toeCenterSpeed2DPerS(.right), signals["toe_speed_right"]!.doubles, "\(label) toe right")
            }
        }
    }

    func testPitSideAndTakeoffFoot() throws {
        for c in try LongJumpCase.all() {
            for call in try c.calls("pit_side_of") {
                XCTAssertEqual(try c.track(call.arg("track")).pitSide(), call.result.side, c.name)
            }
            for call in try c.calls("takeoff_foot") {
                let events = try XCTUnwrap(JumpEvents(fixture: call.arg("events")), c.name)
                XCTAssertEqual(try c.track(call.arg("track")).takeoffFoot(events), call.result.side, c.name)
            }
        }
    }
}
