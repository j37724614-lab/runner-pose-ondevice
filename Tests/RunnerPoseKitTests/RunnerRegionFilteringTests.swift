import CoreGraphics
import CoreVideo
import XCTest
@testable import RunnerPoseKit

final class RunnerRegionFilteringTests: XCTestCase {
    func testRunnerSelectionRejectsPersonOutsideAnchorRegion() {
        var config = Config()
        config.detectorConf = 0.1
        config.minBoxHeight = 10
        config.regionOfInterest = RunnerRegionOfInterest(points: [
            RunnerRegionPoint(x: 100, y: 200),
            RunnerRegionPoint(x: 500, y: 180),
            RunnerRegionPoint(x: 520, y: 400),
            RunnerRegionPoint(x: 80, y: 420),
        ])
        let detector = StubPersonDetector()
        let outside = Detection(
            box: BBox(x1: 740, y1: 50, x2: 900, y2: 300),
            confidence: 0.99
        )
        let inside = Detection(
            box: BBox(x1: 200, y1: 50, x2: 320, y2: 300),
            confidence: 0.80
        )

        let picked = detector.pickRunner(
            [outside, inside],
            near: nil,
            frameSize: CGSize(width: 1920, height: 1080),
            config: config
        )

        XCTAssertEqual(picked?.box, inside.box)
    }

    func testRunnerSelectionReturnsNilWhenAllPeopleAreOutsideAnchorRegion() {
        var config = Config()
        config.detectorConf = 0.1
        config.minBoxHeight = 10
        config.regionOfInterest = RunnerRegionOfInterest(points: [
            RunnerRegionPoint(x: 100, y: 200),
            RunnerRegionPoint(x: 500, y: 200),
            RunnerRegionPoint(x: 500, y: 400),
            RunnerRegionPoint(x: 100, y: 400),
        ])
        let detector = StubPersonDetector()

        let picked = detector.pickRunner(
            [Detection(box: BBox(x1: 600, y1: 50, x2: 750, y2: 300), confidence: 0.99)],
            near: nil,
            frameSize: CGSize(width: 1920, height: 1080),
            config: config
        )

        XCTAssertNil(picked)
    }

    func testProjectionGateUsesServerStartAndEndMargins() {
        let region = RunnerRegionOfInterest(points: [
            RunnerRegionPoint(x: 100, y: 200),
            RunnerRegionPoint(x: 500, y: 200),
            RunnerRegionPoint(x: 500, y: 400),
            RunnerRegionPoint(x: 100, y: 400),
        ])

        XCTAssertTrue(region.contains(BBox(x1: -100, y1: 0, x2: 0, y2: 300)))
        XCTAssertFalse(region.contains(BBox(x1: -250, y1: 0, x2: -150, y2: 300)))
        XCTAssertTrue(region.contains(BBox(x1: 560, y1: 0, x2: 660, y2: 300)))
        XCTAssertFalse(region.contains(BBox(x1: 650, y1: 0, x2: 750, y2: 300)))
    }

    func testProjectionGateMatchesServerLongitudinalSemantics() {
        let region = RunnerRegionOfInterest(points: [
            RunnerRegionPoint(x: 100, y: 200),
            RunnerRegionPoint(x: 500, y: 200),
            RunnerRegionPoint(x: 500, y: 400),
            RunnerRegionPoint(x: 100, y: 400),
        ])

        // Server gates on projection along the runway; lateral distance is a
        // candidate score, not a hard rejection.
        XCTAssertTrue(region.contains(BBox(x1: 200, y1: 700, x2: 300, y2: 900)))
    }
}

private final class StubPersonDetector: PersonDetector {
    func detect(_ frame: CVPixelBuffer, frameSize: CGSize) async throws -> [Detection] { [] }
    func warmUp() async {}
}
