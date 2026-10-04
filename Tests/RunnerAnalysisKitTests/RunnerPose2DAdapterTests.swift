import CoreMedia
import XCTest
import RunnerPoseKit
@testable import RunnerAnalysisKit

final class RunnerPose2DAdapterTests: XCTestCase {
    func testMapsRunnerPoseWithoutLosingFrameIdentityOrCoordinates() {
        let pose = RunnerPose(
            frameIndex: 42,
            timestamp: CMTime(value: 7, timescale: 2),
            bbox: BBox(x1: 10, y1: 20, x2: 110, y2: 220),
            joints: JointName.allCases.map {
                Joint(name: $0, x: Double($0.rawValue), y: Double($0.rawValue + 1), score: 0.9)
            },
            valid: true,
            bboxExtrapolated: true
        )

        let frame = RunnerPose2DAdapter.contractFrame(pose, cameraIndex: 3)

        XCTAssertEqual(frame.cameraIndex, 3)
        XCTAssertEqual(frame.sourceFrame, 42)
        XCTAssertEqual(frame.timestampSeconds, 3.5)
        XCTAssertEqual(frame.bbox, Pose2DBoundingBox(x1: 10, y1: 20, x2: 110, y2: 220))
        XCTAssertEqual(frame.joints.count, 23)
        XCTAssertEqual(frame.joints[22], Pose2DJoint(x: 22, y: 23, score: 0.9))
        XCTAssertTrue(frame.valid)
        XCTAssertTrue(frame.bboxExtrapolated)
    }

    func testMapsInvalidFrameWithNoBoxOrJoints() {
        let pose = RunnerPose(
            frameIndex: 8,
            timestamp: .zero,
            bbox: nil,
            joints: [],
            valid: false,
            bboxExtrapolated: false
        )

        let frame = RunnerPose2DAdapter.contractFrame(pose, cameraIndex: 0)

        XCTAssertNil(frame.bbox)
        XCTAssertTrue(frame.joints.isEmpty)
        XCTAssertFalse(frame.valid)
    }
}
