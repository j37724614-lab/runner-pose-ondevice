import CoreGraphics
import XCTest
@testable import RunnerPoseKit

final class PoseCropBoxTrackerTests: XCTestCase {
    private let frameSize = CGSize(width: 1920, height: 1080)

    func testAdjacentBoxesFollowCenterAndShrinkSizeGradually() {
        var tracker = PoseCropBoxTracker()
        let previous = BBox(x1: 1034.25, y1: 546, x2: 1171.5, y2: 664.5)
        let current = BBox(x1: 1025.25, y1: 543.75, x2: 1116, y2: 660.75)

        XCTAssertEqual(
            tracker.cropBox(for: previous, frame: 685, frameSize: frameSize,
                            centerAlpha: 0.7, shrinkRetention: 0.9),
            previous
        )
        let stable = tracker.cropBox(
            for: current, frame: 686, frameSize: frameSize,
            centerAlpha: 0.7, shrinkRetention: 0.9
        )
        XCTAssertEqual(stable.x1, 1018.5375, accuracy: 0.0001)
        XCTAssertEqual(stable.y1, 544.65, accuracy: 0.0001)
        XCTAssertEqual(stable.x2, 1142.0625, accuracy: 0.0001)
        XCTAssertEqual(stable.y2, 661.65, accuracy: 0.0001)
    }

    func testNonAdjacentFrameStartsANewCropTrack() {
        var tracker = PoseCropBoxTracker()
        _ = tracker.cropBox(
            for: BBox(x1: 100, y1: 100, x2: 200, y2: 300),
            frame: 10,
            frameSize: frameSize, centerAlpha: 0.7, shrinkRetention: 0.9
        )
        let current = BBox(x1: 300, y1: 100, x2: 400, y2: 300)

        XCTAssertEqual(
            tracker.cropBox(for: current, frame: 12, frameSize: frameSize,
                            centerAlpha: 0.7, shrinkRetention: 0.9),
            current
        )
    }

    func testImplausibleCenterJumpDoesNotUnionTracks() {
        var tracker = PoseCropBoxTracker()
        _ = tracker.cropBox(
            for: BBox(x1: 100, y1: 100, x2: 200, y2: 300),
            frame: 10,
            frameSize: frameSize, centerAlpha: 0.7, shrinkRetention: 0.9
        )
        let differentRunner = BBox(x1: 900, y1: 100, x2: 1000, y2: 300)

        XCTAssertEqual(
            tracker.cropBox(for: differentRunner, frame: 11, frameSize: frameSize,
                            centerAlpha: 0.7, shrinkRetention: 0.9),
            differentRunner
        )
    }

    func testResetDropsPreviousBox() {
        var tracker = PoseCropBoxTracker()
        _ = tracker.cropBox(
            for: BBox(x1: 100, y1: 100, x2: 200, y2: 300),
            frame: 10,
            frameSize: frameSize, centerAlpha: 0.7, shrinkRetention: 0.9
        )
        tracker.reset()
        let current = BBox(x1: 120, y1: 100, x2: 180, y2: 300)

        XCTAssertEqual(
            tracker.cropBox(for: current, frame: 11, frameSize: frameSize,
                            centerAlpha: 0.7, shrinkRetention: 0.9),
            current
        )
    }
}
