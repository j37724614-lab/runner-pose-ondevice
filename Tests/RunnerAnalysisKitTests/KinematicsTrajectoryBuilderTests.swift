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

    func testServerAlignedProcessorPublishesDistanceSpeedAndAcceleration() throws {
        var request = requestWithCalibration(AnalysisCalibration(
            startLine: [.init(x: 100, y: 250), .init(x: 100, y: 400)],
            endLine: [.init(x: 700, y: 250), .init(x: 700, y: 400)],
            distanceM: 20
        ))
        request.cameras[0].video.fps = 30
        let frames = (0..<40).map { index -> Pose2DFrame in
            let centerX = 100 + Double(Int(0.4 * Double(index * index)))
            return poseFrame(
                sourceFrame: index,
                timestamp: Double(index) / 30,
                bbox: .init(x1: centerX - 20, y1: 290, x2: centerX + 20, y2: 315)
            )
        }

        let result = try ServerAlignedKinematicsProcessor().process(
            pose2D: Analysis2DResult(frames: frames, durationSeconds: 0),
            request: request
        )

        XCTAssertEqual(result.frames.count, 40)
        XCTAssertTrue(result.frames.allSatisfy { $0.speedModeUsed == "homography" })
        XCTAssertEqual(result.frames.map(\.sourceFrame), Array(0..<40))
        XCTAssertEqual(result.frames.map(\.absoluteFrame), Array(0..<40))
        XCTAssertGreaterThan(result.frames[20].speedMPS, result.frames[10].speedMPS)
        XCTAssertGreaterThan(result.frames[30].distanceM, result.frames[20].distanceM)
        XCTAssertTrue(zip(result.frames, result.frames.dropFirst()).allSatisfy {
            $1.distanceM >= $0.distanceM
        })
        XCTAssertNotNil(result.averageSpeedMPS)
        XCTAssertNotNil(result.averageAccelerationMPS2)
        // Golden values are locked by Server
        // test_compute_speed_from_bbox_map_characterization.py.
        XCTAssertEqual(result.frames[0].distanceM, 0.002, accuracy: 0.01)
        XCTAssertEqual(result.frames[10].distanceM, 1.321, accuracy: 0.02)
        XCTAssertEqual(result.frames[10].speedMPS, 5.399, accuracy: 0.05)
        XCTAssertEqual(result.frames[20].speedMPS, 14.982, accuracy: 0.05)
        XCTAssertEqual(result.frames[30].accelerationMPS2, 23.042, accuracy: 0.1)
        XCTAssertEqual(result.frames[39].distanceM, 20.261, accuracy: 0.02)
    }

    func testServerAlignedProcessorCarriesDistanceAcrossCameras() throws {
        let calibration = AnalysisCalibration(
            startLine: [.init(x: 0, y: 0), .init(x: 0, y: 100)],
            endLine: [.init(x: 100, y: 0), .init(x: 100, y: 100)],
            distanceM: 10
        )
        var request = requestWithCalibration(calibration)
        request.cameras.append(AnalysisCamera(
            cameraIndex: 1,
            video: request.cameras[0].video,
            calibration: calibration
        ))
        let first = (0..<20).map {
            poseFrame(cameraIndex: 0, sourceFrame: $0, timestamp: Double($0) / 60, centerX: 5 * Double($0))
        }
        let second = (0..<20).map {
            poseFrame(cameraIndex: 1, sourceFrame: $0, timestamp: Double(20 + $0) / 60, centerX: 5 * Double($0))
        }

        let result = try ServerAlignedKinematicsProcessor().process(
            pose2D: Analysis2DResult(frames: first + second, durationSeconds: 0),
            request: request
        )
        let camera0 = result.frames.filter { $0.cameraIndex == 0 }
        let camera1 = result.frames.filter { $0.cameraIndex == 1 }

        XCTAssertEqual(camera1.first?.absoluteFrame, 20)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(camera1.first?.distanceM),
            try XCTUnwrap(camera0.last?.distanceM)
        )
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
    cameraIndex: Int = 0,
    sourceFrame: Int,
    timestamp: Double,
    bbox: Pose2DBoundingBox?
) -> Pose2DFrame {
    Pose2DFrame(
        cameraIndex: cameraIndex,
        sourceFrame: sourceFrame,
        timestampSeconds: timestamp,
        bbox: bbox,
        joints: [],
        valid: true,
        bboxExtrapolated: false
    )
}

private func poseFrame(
    cameraIndex: Int,
    sourceFrame: Int,
    timestamp: Double,
    centerX: Double
) -> Pose2DFrame {
    poseFrame(
        cameraIndex: cameraIndex,
        sourceFrame: sourceFrame,
        timestamp: timestamp,
        bbox: .init(x1: centerX - 10, y1: 20, x2: centerX + 10, y2: 80)
    )
}
