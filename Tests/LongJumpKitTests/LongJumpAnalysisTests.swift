import XCTest
@testable import LongJumpKit

/// The whole analysis end to end against the server's analyse_long_jump on every recorded attempt:
/// same pose file, first frame, pit calibration and (for the sand mark) the runner masks the
/// server's segmenter returned.  The complete result document, internal "_" keys included, must
/// be identical.
final class LongJumpAnalysisTests: XCTestCase {

    /// Replays the runner masks recorded in a case's _nearest_contact_in_batch calls.
    private struct RecordedMasks: RunnerMaskSource {
        var byFrame: [Int: RunnerMask]
        func runnerMask(frame: Int, box: SIMD4<Double>) throws -> RunnerMask? { byFrame[frame] }
    }

    private func recordedMasks(_ c: LongJumpCase) throws -> RecordedMasks? {
        var byFrame: [Int: RunnerMask] = [:]
        let calls = try c.calls("_nearest_contact_in_batch")
        guard !calls.isEmpty else { return nil }
        for call in calls {
            let batch = try call.arg("batch").arrayValue ?? []
            for (item, mask) in zip(batch, call.masks ?? []) {
                if let full = mask.mask { byFrame[item["frame"]!.intValue!] = RunnerMask(fullFrame: full) }
            }
        }
        return RecordedMasks(byFrame: byFrame)
    }

    func testWholeAnalysisMatchesTheServer() throws {
        var compared = 0
        for c in try LongJumpCase.all() {
            let data = try Data(contentsOf: c.folder.appendingPathComponent("pose/keypoints_2d.json"))
            let result = LongJumpAnalysis.analyse(
                keypointsJSON: data, cameraIndex: c.cameraIndex, firstFrame: try c.firstFrame(),
                pit: c.pit, sandMarks: try recordedMasks(c)
            )
            // 1e-6: every number but one matches exactly; the drawn line of the partly covered
            // board (session_9b749ffa) is the inverse of a 5-6 point homography, which only matches
            // OpenCV to ~1e-9 relative (3e-12 px here).  Rounded fields differ by >= 1e-4, so a
            // rounding mistake still fails.
            let differences = jsonDifferences(.object(result), try c.result(), tolerance: 1e-6)
            XCTAssertTrue(differences.isEmpty, "\(c.name):\n" + differences.prefix(20).joined(separator: "\n"))
            compared += 1
        }
        print("analyse_long_jump replayed: \(compared)")
    }

    func testPublicResultDropsInternalKeys() throws {
        let c = try XCTUnwrap(LongJumpCase.all().first { $0.name.hasPrefix("session_") })
        let data = try Data(contentsOf: c.folder.appendingPathComponent("pose/keypoints_2d.json"))
        let result = LongJumpAnalysis.analyse(keypointsJSON: data, cameraIndex: c.cameraIndex, pit: c.pit)
        let clean = LongJumpAnalysis.publicResult(result)
        XCTAssertFalse(clean.keys.contains { $0.hasPrefix("_") })
        XCTAssertTrue(result.keys.contains("_overlay"))
        // no first frame: no board check, no sand-mark search, the heel distance still stands
        XCTAssertNotNil(clean["distance"]?["official_m"]?.doubleValue)
    }

    func testTrackingLostWhenThePoseFileIsUnusable() {
        let result = LongJumpAnalysis.analyse(keypointsJSON: Data(#"{"frames": [], "joint_order": []}"#.utf8))
        XCTAssertEqual(result["status"], "tracking_lost")
        XCTAssertEqual(result["warnings"], ["pose: no valid pose frames"])
    }
}
