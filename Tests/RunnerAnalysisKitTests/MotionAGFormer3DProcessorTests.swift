import Foundation
import XCTest
@testable import RunnerAnalysisKit

final class MotionAGFormer3DProcessorTests: XCTestCase {
    func testEndToEndProcessorRestoresOriginalFrameIdentity() async throws {
        let processor = MotionAGFormer3DProcessor(predictor: EchoMotionPredictor())
        let request = AnalysisRequest(
            analysisKind: .longJump,
            cameras: [
                AnalysisCamera(
                    cameraIndex: 0,
                    video: AnalysisVideo(
                        uri: "/tmp/input.mov",
                        sha256: String(repeating: "a", count: 64),
                        fps: 60,
                        width: 1000,
                        height: 500,
                        frameCount: 100,
                        rotationDegrees: 0
                    )
                ),
            ]
        )

        let result = try await processor.process(
            pose2D: Analysis2DResult(frames: [wholeBodyFrame()], durationSeconds: 0),
            request: request
        )

        XCTAssertEqual(result.frames.count, 1)
        XCTAssertEqual(result.frames[0].cameraIndex, 0)
        XCTAssertEqual(result.frames[0].sourceFrame, 42)
        XCTAssertEqual(result.frames[0].timestampSeconds, 0.7)
        XCTAssertEqual(result.frames[0].joints.count, 17)
        XCTAssertEqual(result.angles[0].sourceFrame, 42)
    }

    func testWholeBody23ConversionMatchesServerH36MJointSides() {
        let frame = wholeBodyFrame()

        let converted = MotionAGFormer3DProcessor.convertWholeBody23ToH36M17(frame)

        XCTAssertEqual(converted.metadata.sourceFrame, 42)
        XCTAssertEqual(converted.values.count, 17 * 3)
        assertJoint(converted.values, index: 11, equalsWholeBodyJoint: 5)
        assertJoint(converted.values, index: 12, equalsWholeBodyJoint: 7)
        assertJoint(converted.values, index: 13, equalsWholeBodyJoint: 9)
        assertJoint(converted.values, index: 14, equalsWholeBodyJoint: 6)
        assertJoint(converted.values, index: 15, equalsWholeBodyJoint: 8)
        assertJoint(converted.values, index: 16, equalsWholeBodyJoint: 10)
    }

    func testShortSequenceResamplingRetainsEveryOriginalSourceFrame() {
        let frames = (0..<3).map { index in
            MotionAGFormer3DProcessor.H36M2DFrame(
                metadata: .init(cameraIndex: 0, sourceFrame: 10 + index, timestampSeconds: Double(index)),
                values: Array(repeating: Float(index), count: 17 * 3)
            )
        }

        let windows = MotionAGFormer3DProcessor.windows(frames: frames)

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].padded.count, 243)
        XCTAssertEqual(windows[0].outputPositions, [0, 81, 162])
        XCTAssertEqual(windows[0].outputPositions.map {
            windows[0].padded[$0].metadata.sourceFrame
        }, [10, 11, 12])
    }

    func testFlipIsItsOwnInverse() {
        let values = (0..<CoreMLMotionAGFormerPredictor.elementCount).map { Float($0) }
        XCTAssertEqual(MotionAGFormer3DProcessor.unflip(
            MotionAGFormer3DProcessor.flip(values)
        ), values)
    }

    func testAngleCalculationRetainsRawValuesAndComputesRightAngle() throws {
        var joints = Array(repeating: Pose3DJoint(x: 0, y: 0, z: 0), count: 17)
        joints[4] = Pose3DJoint(x: 0, y: 1, z: 0)
        joints[5] = Pose3DJoint(x: 0, y: 0, z: 0)
        joints[6] = Pose3DJoint(x: 1, y: 0, z: 0)
        let frame = Pose3DFrame(cameraIndex: 0, sourceFrame: 9, timestampSeconds: 0.3, joints: joints)

        let angles = AnalysisAngleCalculator.compute(frames: [frame])

        XCTAssertEqual(try XCTUnwrap(angles[0].rawValuesDegrees?["left_knee_angle"]), 90, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(angles[0].valuesDegrees["left_knee_angle"]), 90, accuracy: 1e-8)
    }

    func testSavitzkyGolayPreservesConstantSeries() {
        let values = Array(repeating: 37.5, count: 31)
        let smoothed = AnalysisAngleCalculator.savitzkyGolay(
            values,
            window: 7,
            polynomialOrder: 3
        )
        for value in smoothed {
            XCTAssertEqual(value, 37.5, accuracy: 1e-10)
        }
    }
}

private struct EchoMotionPredictor: MotionAGFormerPredicting {
    func predict(input: [Float]) async throws -> [Float] { input }
}

private func wholeBodyFrame() -> Pose2DFrame {
    Pose2DFrame(
        cameraIndex: 0,
        sourceFrame: 42,
        timestampSeconds: 0.7,
        bbox: Pose2DBoundingBox(x1: 0, y1: 0, x2: 100, y2: 100),
        joints: (0..<23).map {
            Pose2DJoint(x: Double($0 * 10), y: Double($0 * 10 + 1), score: Double($0) / 100)
        },
        valid: true,
        bboxExtrapolated: false
    )
}

private func assertJoint(
    _ values: [Float],
    index: Int,
    equalsWholeBodyJoint sourceIndex: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(values[index * 3], Float(sourceIndex * 10), file: file, line: line)
    XCTAssertEqual(values[index * 3 + 1], Float(sourceIndex * 10 + 1), file: file, line: line)
    XCTAssertEqual(values[index * 3 + 2], Float(sourceIndex) / 100, file: file, line: line)
}
