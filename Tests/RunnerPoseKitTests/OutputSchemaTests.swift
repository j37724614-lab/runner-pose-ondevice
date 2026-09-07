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
