import XCTest
@testable import RunnerPoseKit

/// The 23-joint order is a hard contract with the downstream pipeline
/// (leg-identity / MotionAGFormer / gait). If this breaks, downstream breaks
/// silently (規劃書 §02 輸出 schema, §12 硬性 gate).
///
/// TODO(mac): extend to compare a real `RunnerPose` export against a frozen
/// `hrnet_2d.csv` / keypoints JSON from a current pipeline run (規劃書 §05 P1
/// `OutputSchemaTests` — 逐欄位比對). Drop that fixture into Fixtures/schema/.
final class OutputSchemaTests: XCTestCase {
    func testDefaultConfigDetectsEveryFrame() {
        let config = Config()

        XCTAssertEqual(config.detectorModel, .yolo26l)
        XCTAssertEqual(config.detectorCadence, 1)
    }

    func testRunnerRegionUsesBoundingBoxGroundPoint() throws {
        let region = RunnerRegionOfInterest(points: [
            RunnerRegionPoint(x: 100, y: 200),
            RunnerRegionPoint(x: 500, y: 180),
            RunnerRegionPoint(x: 520, y: 400),
            RunnerRegionPoint(x: 80, y: 420),
        ])

        let projection = try XCTUnwrap(
            region.projection(BBox(x1: 200, y1: 100, x2: 300, y2: 300))
        )
        XCTAssertEqual(projection, 160.3, accuracy: 0.1)
        XCTAssertTrue(region.contains(BBox(x1: 200, y1: 100, x2: 300, y2: 300)))
        XCTAssertFalse(region.contains(BBox(x1: 700, y1: 100, x2: 800, y2: 300)))
    }

    func testJointSidesSeparateLeftAndRightLimbs() {
        XCTAssertEqual(JointName.leftAnkle.side, .left)
        XCTAssertEqual(JointName.leftHeel.side, .left)
        XCTAssertEqual(JointName.rightAnkle.side, .right)
        XCTAssertEqual(JointName.rightHeel.side, .right)
        XCTAssertEqual(JointName.nose.side, .center)
    }

    /// Canonical order — `HRNetRunnerWholeBody23.conversion.json` `joint_names`.
    let canonical = [
        "nose", "left_eye", "right_eye", "left_ear", "right_ear",
        "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
        "left_wrist", "right_wrist", "left_hip", "right_hip",
        "left_knee", "right_knee", "left_ankle", "right_ankle",
        "left_big_toe", "left_small_toe", "left_heel",
        "right_big_toe", "right_small_toe", "right_heel",
    ]

    func testJointOrderMatchesModelContract() {
        XCTAssertEqual(JointName.count, 23)
        XCTAssertEqual(JointName.allCases.count, 23)
        for (i, name) in canonical.enumerated() {
            let j = JointName(rawValue: i)
            XCTAssertNotNil(j, "no joint at index \(i)")
            XCTAssertEqual(String(describing: j!).toSnake(), name, "joint \(i)")
        }
        XCTAssertEqual(JointName.leftAnkle.rawValue, 15)
        XCTAssertEqual(JointName.rightHeel.rawValue, 22)
    }

    func testLegacyBenchReportWithoutPowerStillDecodes() throws {
        let json = #"""
        {
          "id":"6D318A5F-2F98-47C8-8D95-67D2C53D6CBC",
          "startedAt":"2026-10-03T18:24:20Z",
          "conditions":{
            "detectorModel":"yolo26l","detectorCadence":1,"computeUnits":"cpuAndNeuralEngine",
            "maxInFlight":3,"videoName":"fixture.mov","videoFrames":10,"videoFPS":60,
            "deviceModel":"iPhone","osVersion":"26.3","appBuild":"debug",
            "startThermalState":"nominal","startBatteryLevel":1,
            "implementationVariant":"naive","runIndex":1,"warmupRuns":3
          },
          "totals":{
            "wallClockSeconds":1,"framesProcessed":10,"framesSkippedByGate":0,
            "validRangeFrames":10,"totalVideoFrames":10,"effectiveFPS":10,
            "modelLoadSeconds":0,"prescanSeconds":0,"prescanKeptRatio":1,
            "detectionFrames":10,"extrapolatedFrames":0
          },
          "stages":{},
          "memory":{"peakMB":100,"samplesMB":[100],"receivedMemoryWarning":false},
          "thermal":[{"atSeconds":0,"state":"nominal"}]
        }
        """#.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(BenchReport.self, from: json)
        XCTAssertNil(report.power)
        XCTAssertEqual(report.conditions.deviceModel, "iPhone")
    }
}

private extension String {
    /// leftBigToe -> left_big_toe
    func toSnake() -> String {
        var out = ""
        for ch in self {
            if ch.isUppercase { out += "_" + ch.lowercased() } else { out.append(ch) }
        }
        return out
    }
}
