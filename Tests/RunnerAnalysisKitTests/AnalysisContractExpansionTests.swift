import Foundation
import XCTest
@testable import RunnerAnalysisKit

final class AnalysisContractExpansionTests: XCTestCase {
    func testKinematicsPolicyAndROIEncodeWithCanonicalKeys() throws {
        let request = AnalysisRequest(
            requestID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            analysisKind: .longJump,
            cameras: [AnalysisCamera(
                cameraIndex: 0,
                video: AnalysisVideo(
                    uri: "file:///input.mov",
                    sha256: String(repeating: "a", count: 64),
                    fps: 60,
                    width: 1920,
                    height: 1080,
                    frameCount: 600,
                    rotationDegrees: 0
                ),
                calibration: AnalysisCalibration(
                    roiX: [100, 1800],
                    roiY: [700, 900]
                )
            )],
            kinematicsPolicy: AnalysisKinematicsPolicy(
                speedMode: .homography,
                butterworthCutoffHz: 4,
                flatInterpolationEpsilonM: 0.002,
                laneWidthM: 1.25
            )
        )

        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let policy = try XCTUnwrap(json["kinematics_policy"] as? [String: Any])
        XCTAssertEqual(policy["speed_mode"] as? String, "homography")
        XCTAssertEqual(policy["butterworth_cutoff_hz"] as? Double, 4)
        XCTAssertEqual(policy["flat_interpolation_epsilon_m"] as? Double, 0.002)
        XCTAssertEqual(policy["lane_width_m"] as? Double, 1.25)
        let cameras = try XCTUnwrap(json["cameras"] as? [[String: Any]])
        let calibration = try XCTUnwrap(cameras[0]["calibration"] as? [String: Any])
        XCTAssertEqual(calibration["roi_x"] as? [Double], [100, 1800])
        XCTAssertEqual(calibration["roi_y"] as? [Double], [700, 900])
    }

    func testMissingOptionalKinematicsPolicyDecodesToDocumentedDefaults() throws {
        let request = AnalysisRequest(
            analysisKind: .running,
            cameras: [AnalysisCamera(
                cameraIndex: 0,
                video: AnalysisVideo(
                    uri: "file:///input.mov",
                    sha256: String(repeating: "a", count: 64),
                    fps: 60,
                    width: 1920,
                    height: 1080,
                    frameCount: 600,
                    rotationDegrees: 0
                )
            )]
        )
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        json.removeValue(forKey: "kinematics_policy")

        let decoded = try JSONDecoder().decode(
            AnalysisRequest.self,
            from: JSONSerialization.data(withJSONObject: json)
        )

        XCTAssertEqual(decoded.kinematicsPolicy, AnalysisKinematicsPolicy())
    }

    /// With homography calibration the pixel series is unavailable. The
    /// kinematics schema still requires those keys (as null); omitting them
    /// made backend ingestion reject every calibrated Local run with 422.
    func testKinematicsFrameEncodesMissingSeriesAsExplicitNull() throws {
        let frame = AnalysisKinematicsFrame(
            cameraIndex: 0,
            cameraFrame: 0,
            sourceFrame: 594,
            absoluteFrame: 0,
            timestampSeconds: 9.91,
            distanceM: 1.2,
            rawDistanceM: nil,
            smoothDistanceM: 1.2,
            speedMPS: 7.5,
            accelerationMPS2: 2.1,
            speedModeUsed: "homography",
            pixelDistanceM: nil,
            pixelSpeedMPS: nil,
            pixelAccelerationMPS2: nil,
            homographyDistanceM: 1.2,
            homographySpeedMPS: 7.5,
            homographyAccelerationMPS2: 2.1,
            imagePointX: 320,
            imagePointY: 800,
            isInterpolated: false,
            interpolationGapLength: 0,
            confidence: 1
        )

        let data = try JSONEncoder().encode(frame)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["raw_distance_m", "pixel_distance_m", "pixel_speed_mps", "pixel_acceleration_mps2"] {
            XCTAssertTrue(json[key] is NSNull, "\(key) must be present as null")
        }
        XCTAssertEqual(json.count, 22)
        XCTAssertEqual(try JSONDecoder().decode(AnalysisKinematicsFrame.self, from: data), frame)
    }
}
