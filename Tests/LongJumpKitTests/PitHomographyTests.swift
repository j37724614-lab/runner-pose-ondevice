import XCTest
@testable import LongJumpKit

final class PitHomographyTests: XCTestCase {
    func runCases() throws -> (Double, Double, Double) {
        let cases = try XCTUnwrap(Fixtures.unit("opencv")["homography"]?.arrayValue)
        XCTAssertEqual(cases.count, 9)
        var worstMatrix = 0.0, worstWorld = 0.0, worstBack = 0.0
        for c in cases {
            let cal = PitCalibration(
                imagePoints: c["image_points"]!.arrayValue!.map { $0.point2 },
                worldPoints: c["world_points"]!.arrayValue!.map { $0.point2 })
            let h = try PitHomography(cal)
            let expected = c["matrix"]!.arrayValue!.map { $0.doubles }
            for i in 0..<3 { for j in 0..<3 {
                let rel = abs(h.matrix[i][j] - expected[i][j]) / max(abs(expected[i][j]), 1e-300)
                worstMatrix = max(worstMatrix, rel)
            } }
            let probe = c["probe_image"]!.arrayValue!.map { $0.point2 }
            let world = h.toWorld(probe)
            let ew = c["probe_world"]!.arrayValue!.map { $0.point2 }
            for (a, e) in zip(world, ew) { worstWorld = max(worstWorld, abs(a.x - e.x), abs(a.y - e.y)) }
            let back = h.toImage(ew)
            let eb = c["probe_back"]!.arrayValue!.map { $0.point2 }
            for (a, e) in zip(back, eb) { worstBack = max(worstBack, abs(a.x - e.x), abs(a.y - e.y)) }
        }
        return (worstMatrix, worstWorld, worstBack)
    }
    func testHomographyFixture() throws {
        let (worstMatrix, worstWorld, worstBack) = try runCases()
        print("HOMOGRAPHY worst matrix rel \(worstMatrix) world \(worstWorld) back \(worstBack)")
        XCTAssertLessThan(worstMatrix, 1e-9)
        XCTAssertLessThan(worstWorld, 1e-9)
        XCTAssertLessThan(worstBack, 1e-9)
    }
}

// MARK: - Fixture decoding shared by the distance tests

extension PitCalibration {
    init?(fixture value: JSONValue) {
        guard value["$type"]?.stringValue == "PitCalibration" else { return nil }
        self.init(
            imagePoints: value["image_points"]!.arrayValue!.map { $0.point2 },
            worldPoints: value["world_points"]!.arrayValue!.map { $0.point2 },
            boardOffsetM: value["board_offset_m"]!.doubleValue!)
    }
}

var homographyWorstWorld = 0.0

/// Rebuilds a recorded PitHomography from its calibration and asserts the recorded matrix.
func homography(fixture value: JSONValue?, file: StaticString = #filePath, line: UInt = #line) throws -> PitHomography? {
    guard let value, value["$type"]?.stringValue == "PitHomography" else { return nil }
    let calibration = try XCTUnwrap(PitCalibration(fixture: value["calibration"]!), file: file, line: line)
    let cal = calibration
    let h = try PitHomography(calibration)
    let expected = value["matrix"]!.arrayValue!.map { $0.doubles }
    for i in 0..<3 {
        for j in 0..<3 {
            let rel = abs(h.matrix[i][j] - expected[i][j]) / max(abs(expected[i][j]), 1e-300)
            // Tiny entries (1e-6) of the real-session matrices differ up to ~1e-8 relative: the LM
            // refinement walks a flat valley and its result there depends on OpenBLAS's rounding.
            XCTAssertLessThan(rel, 5e-8, "matrix[\(i)][\(j)]", file: file, line: line)
        }
    }
    // What matters is the mapping: calibration points and far image points land within 1e-6 m.
    var worst = 0.0
    let flat = expected.flatMap { $0 }
    for p in cal.imagePoints + [SIMD2(0, 0), SIMD2(1920, 1080), SIMD2(1920, 400), SIMD2(0, 1080)] {
        let w = h.toWorld(p)
        let e = PitHomography.transform(p, flat)
        worst = max(worst, abs(w.x - e.x), abs(w.y - e.y))
    }
    XCTAssertLessThan(worst, 1e-6, "world", file: file, line: line)
    homographyWorstWorld = max(homographyWorstWorld, worst)
    XCTAssertEqual(h.rmsM, value["rms_m"]!.doubleValue!, accuracy: 1e-9, file: file, line: line)
    XCTAssertEqual(h.xRange.0, value["x_range"]!.doubles[0], file: file, line: line)
    XCTAssertEqual(h.xRange.1, value["x_range"]!.doubles[1], file: file, line: line)
    return h
}

func jsonObject(_ value: JSONValue?) -> JSONObject { value?.objectValue ?? JSONObject() }
