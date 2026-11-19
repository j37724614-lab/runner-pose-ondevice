import CoreML
import XCTest
@testable import RunnerPoseKit

/// `SimCCKeypointDecoder` must decode exactly like the pipeline's reference
/// (core/pose_models/simcc.py). Fixtures: scripts/pose_models/make_simcc_fixture.py.
/// TODO(mac): first run on the Mac.
final class SimCCDecoderTests: XCTestCase {

    struct Case: Decodable {
        var name: String
        var split_ratio: Double
        var simcc_x: [[Double]]
        var simcc_y: [[Double]]
        var expected_points: [[Double]]
        var expected_scores: [Double]
    }

    struct FixtureFile: Decodable {
        var cases: [Case]
    }

    func testCropDecodingMatchesThePipelineReference() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures", withExtension: nil)?
                .appendingPathComponent("simcc/simcc_decode_cases.json"),
            "missing fixture: run scripts/pose_models/make_simcc_fixture.py"
        )
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertFalse(fixture.cases.isEmpty)
        for c in fixture.cases {
            let decoded = SimCCKeypointDecoder.decodeCrop(rowsX: c.simcc_x, rowsY: c.simcc_y, splitRatio: c.split_ratio)
            XCTAssertEqual(decoded.count, c.expected_points.count, c.name)
            for (k, (point, score)) in decoded.enumerated() {
                XCTAssertEqual(point.x, c.expected_points[k][0], accuracy: 1e-9, "\(c.name) keypoint \(k) x")
                XCTAssertEqual(point.y, c.expected_points[k][1], accuracy: 1e-9, "\(c.name) keypoint \(k) y")
                XCTAssertEqual(score, c.expected_scores[k], accuracy: 1e-9, "\(c.name) keypoint \(k) score")
            }
        }
    }

    func testArgmaxTakesTheFirstOfEqualMaxima() {
        let (index, value) = SimCCKeypointDecoder.argmax([0.1, 0.7, 0.7, 0.2])
        XCTAssertEqual(index, 1)
        XCTAssertEqual(value, 0.7)
    }

    func testRowsReadBatchedMultiArrays() throws {
        let array = try MLMultiArray(shape: [1, 2, 3], dataType: .float32)
        for k in 0..<2 {
            for i in 0..<3 {
                array[[0, NSNumber(value: k), NSNumber(value: i)]] = NSNumber(value: Float(k * 10 + i))
            }
        }
        let rows = try SimCCKeypointDecoder.rows(array, name: "simcc_x")
        XCTAssertEqual(rows, [[0, 1, 2], [10, 11, 12]])
    }

    func testHeatmapOutputIsRefused() throws {
        let spec = try JSONDecoder().decode(PoseModelSpec.self, from: Data(PoseModelSpecTests.bodyOnlySimCC.utf8))
        let decoder = try SimCCKeypointDecoder(spec: spec)
        let heatmap = try MLMultiArray(shape: [1, 1, 2, 2], dataType: .float32)
        XCTAssertThrowsError(try decoder.decode(.heatmap(heatmap), center: .zero, scale: SIMD2(1, 1)))
    }
}
