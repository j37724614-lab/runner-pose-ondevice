import XCTest
@testable import RunnerAnalysisKit

final class KinematicsTrajectoryBuilderTests: XCTestCase {
    func testAutomaticLineHomographyUsesExplicitSourceTime() throws {
        let request = requestWithCalibration(AnalysisCalibration(
            startLine: [.init(x: 0, y: 0), .init(x: 0, y: 100)],
            endLine: [.init(x: 100, y: 0), .init(x: 100, y: 100)],
            distanceM: 10
        ))
        let frame = poseFrame(sourceFrame: 120, timestamp: 2.0, bbox: .init(
            x1: 40, y1: 20, x2: 60, y2: 80
        ))

        let samples = try KinematicsTrajectoryBuilder.build(
            pose2D: Analysis2DResult(frames: [frame], durationSeconds: 0),
            request: request
        )

        XCTAssertEqual(samples[0].sourceFrame, 120)
        XCTAssertEqual(samples[0].timestampSeconds, 2.0)
        XCTAssertEqual(samples[0].centerX, 50)
        XCTAssertEqual(samples[0].bottomCenterY, 80)
        XCTAssertNil(samples[0].pixelDistanceM)
        XCTAssertEqual(try XCTUnwrap(samples[0].homographyDistanceM), 5, accuracy: 1e-8)
    }

    func testHomographyUsesBottomCenterProjectedOntoTrackCenterline() throws {
        let calibration = AnalysisCalibration(
            startLine: [.init(x: 0, y: 0), .init(x: 0, y: 100)],
            endLine: [.init(x: 100, y: 0), .init(x: 100, y: 100)],
            distanceM: 10,
            homographyImagePoints: [
                .init(x: 0, y: 0), .init(x: 0, y: 100),
                .init(x: 100, y: 0), .init(x: 100, y: 100),
            ],
            homographyWorldPointsM: [
                .init(x: 0, y: 0), .init(x: 0, y: 1.22),
                .init(x: 10, y: 0), .init(x: 10, y: 1.22),
            ]
        )
        let frame = poseFrame(sourceFrame: 3, timestamp: 0.05, bbox: .init(
            x1: 40, y1: 20, x2: 60, y2: 90
        ))

        let samples = try KinematicsTrajectoryBuilder.build(
            pose2D: Analysis2DResult(frames: [frame], durationSeconds: 0),
            request: requestWithCalibration(calibration)
        )

        XCTAssertEqual(try XCTUnwrap(samples[0].homographyDistanceM), 5, accuracy: 1e-8)
    }

    func testInterpolationConfidenceMatchesServerGapBuckets() {
        XCTAssertEqual(
            KinematicsTrajectoryBuilder.interpolationConfidences([
                false, true, true, false,
                true, true, true, true, false,
                true, true, true, true, true, true, true, true, true,
            ]),
            [
                1, 0.7, 0.7, 1,
                0.4, 0.4, 0.4, 0.4, 1,
                0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2,
            ]
        )
    }

    func testFrameWithoutBoundingBoxIsSkipped() throws {
        let frame = poseFrame(sourceFrame: 8, timestamp: 0.1, bbox: nil)

        let samples = try KinematicsTrajectoryBuilder.build(
            pose2D: Analysis2DResult(frames: [frame], durationSeconds: 0),
            request: requestWithCalibration(AnalysisCalibration())
        )

        XCTAssertTrue(samples.isEmpty)
    }
}

private func requestWithCalibration(_ calibration: AnalysisCalibration) -> AnalysisRequest {
    AnalysisRequest(
        analysisKind: .longJump,
        cameras: [
            AnalysisCamera(
                cameraIndex: 0,
                video: AnalysisVideo(
                    uri: "/tmp/input.mov",
                    sha256: String(repeating: "a", count: 64),
                    fps: 60,
                    width: 1920,
                    height: 1080,
                    frameCount: 300,
                    rotationDegrees: 0
                ),
                calibration: calibration
            ),
        ]
    )
}

private func poseFrame(
    sourceFrame: Int,
    timestamp: Double,
    bbox: Pose2DBoundingBox?
) -> Pose2DFrame {
    Pose2DFrame(
        cameraIndex: 0,
        sourceFrame: sourceFrame,
        timestampSeconds: timestamp,
        bbox: bbox,
        joints: [],
        valid: true,
        bboxExtrapolated: false
    )
}
