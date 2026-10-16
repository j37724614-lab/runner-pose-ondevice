import Foundation
import XCTest
@testable import RunnerAnalysisKit

final class GaitAndGroundPointTests: XCTestCase {
    func testGroundPointStabilizerRepairsSingleTightShiftedBox() throws {
        var frames = (0..<7).map { index in
            frame(
                sourceFrame: index,
                bbox: Pose2DBoundingBox(
                    x1: Double(100 + index * 10), y1: 100,
                    x2: Double(180 + index * 10), y2: 300
                )
            )
        }
        frames[3].bbox = Pose2DBoundingBox(x1: 155, y1: 180, x2: 175, y2: 260)

        let result = GroundPointStabilizer.stabilize(frames: frames)
        let repaired = try XCTUnwrap(result[3])

        XCTAssertEqual(repaired.x, 170, accuracy: 0.001)
        XCTAssertEqual(repaired.bottomY, 300, accuracy: 0.001)
        XCTAssertTrue(repaired.repaired)
        XCTAssertEqual(repaired.confidence, 0.25, accuracy: 0.001)
    }

    func testGaitProcessorDetectsAlternatingTouchdownsAndMetricSteps() throws {
        let fps = 60.0
        let touchdownFrames = [12, 24, 36, 48, 60, 72]
        let frames = (0..<84).map { index -> Pose2DFrame in
            var joints = baselineJoints(x: 100 + Double(index) * 6)
            for touchdown in touchdownFrames {
                let distance = abs(index - touchdown)
                let pulse = max(0, 36 - Double(distance * distance) * 9)
                if touchdownFrames.firstIndex(of: touchdown)!.isMultiple(of: 2) {
                    joints[15].y += pulse
                    joints[17].y += pulse
                    joints[18].y += pulse
                    joints[19].y += pulse
                } else {
                    joints[16].y += pulse
                    joints[20].y += pulse
                    joints[21].y += pulse
                    joints[22].y += pulse
                }
            }
            return Pose2DFrame(
                cameraIndex: 0,
                sourceFrame: index,
                timestampSeconds: Double(index) / fps,
                bbox: Pose2DBoundingBox(
                    x1: 60 + Double(index) * 6, y1: 100,
                    x2: 160 + Double(index) * 6, y2: 360
                ),
                joints: joints,
                valid: true,
                bboxExtrapolated: false
            )
        }
        let request = AnalysisRequest(
            analysisKind: .running,
            cameras: [AnalysisCamera(
                cameraIndex: 0,
                video: AnalysisVideo(
                    uri: "/tmp/gait.mov",
                    sha256: String(repeating: "a", count: 64),
                    fps: fps,
                    width: 1920,
                    height: 1080,
                    frameCount: frames.count,
                    rotationDegrees: 0
                ),
                calibration: AnalysisCalibration(
                    startLine: [AnalysisPoint(x: 100, y: 250), AnalysisPoint(x: 100, y: 350)],
                    endLine: [AnalysisPoint(x: 700, y: 250), AnalysisPoint(x: 700, y: 350)],
                    distanceM: 12
                )
            )]
        )

        let result = try ServerAlignedGaitProcessor().process(
            pose2D: Analysis2DResult(frames: frames, durationSeconds: 1.4),
            kinematics: nil,
            request: request
        )

        XCTAssertGreaterThanOrEqual(result.steps.steps.count, 5)
        XCTAssertNotNil(result.steps.averageCadenceSPM)
        XCTAssertNotNil(result.steps.averageStepLengthM)
        XCTAssertTrue(result.steps.steps.dropFirst().allSatisfy { $0.stepLengthM != nil })
        XCTAssertTrue(result.contactEvents.contains { $0.eventType == .toeOff })
        XCTAssertEqual(
            Array(result.steps.steps.prefix(4).map(\.foot)),
            [.left, .right, .left, .right]
        )
    }

    func testTemporalLegIdentityRecordsOneFrameSwap() throws {
        var frames: [Pose2DFrame] = []
        for index in 0..<12 {
            var joints = baselineJoints(x: 200 + Double(index))
            if index == 6 {
                for pair in [(11, 12), (13, 14), (15, 16), (17, 20), (18, 21), (19, 22)] {
                    joints.swapAt(pair.0, pair.1)
                }
            }
            frames.append(Pose2DFrame(
                cameraIndex: 0,
                sourceFrame: index,
                timestampSeconds: Double(index) / 60,
                bbox: Pose2DBoundingBox(x1: 150, y1: 100, x2: 280, y2: 340),
                joints: joints,
                valid: true,
                bboxExtrapolated: false
            ))
        }
        let request = AnalysisRequest(
            analysisKind: .running,
            cameras: [AnalysisCamera(
                cameraIndex: 0,
                video: AnalysisVideo(
                    uri: "/tmp/swap.mov",
                    sha256: String(repeating: "b", count: 64),
                    fps: 60,
                    width: 1920,
                    height: 1080,
                    frameCount: frames.count,
                    rotationDegrees: 0
                )
            )]
        )

        let result = try ServerAlignedGaitProcessor().process(
            pose2D: Analysis2DResult(frames: frames, durationSeconds: 0.2),
            kinematics: nil,
            request: request
        )

        XCTAssertEqual(result.legIdentityFrames.first { $0.sourceFrame == 6 }?.swapped, true)
        XCTAssertEqual(result.legIdentityFrames.first { $0.sourceFrame == 6 }?.reason, .temporalDP)
    }
}

private func frame(sourceFrame: Int, bbox: Pose2DBoundingBox) -> Pose2DFrame {
    Pose2DFrame(
        cameraIndex: 0,
        sourceFrame: sourceFrame,
        timestampSeconds: Double(sourceFrame) / 60,
        bbox: bbox,
        joints: [],
        valid: true,
        bboxExtrapolated: false
    )
}

private func baselineJoints(x: Double) -> [Pose2DJoint] {
    var joints = Array(repeating: Pose2DJoint(x: x, y: 200, score: 0.95), count: 23)
    joints[11] = Pose2DJoint(x: x - 10, y: 220, score: 0.95)
    joints[12] = Pose2DJoint(x: x + 10, y: 220, score: 0.95)
    joints[13] = Pose2DJoint(x: x - 14, y: 260, score: 0.95)
    joints[14] = Pose2DJoint(x: x + 14, y: 260, score: 0.95)
    joints[15] = Pose2DJoint(x: x - 18, y: 300, score: 0.95)
    joints[16] = Pose2DJoint(x: x + 18, y: 300, score: 0.95)
    joints[17] = Pose2DJoint(x: x - 10, y: 302, score: 0.90)
    joints[18] = Pose2DJoint(x: x - 14, y: 302, score: 0.90)
    joints[19] = Pose2DJoint(x: x - 22, y: 303, score: 0.90)
    joints[20] = Pose2DJoint(x: x + 26, y: 302, score: 0.90)
    joints[21] = Pose2DJoint(x: x + 22, y: 302, score: 0.90)
    joints[22] = Pose2DJoint(x: x + 14, y: 303, score: 0.90)
    return joints
}
