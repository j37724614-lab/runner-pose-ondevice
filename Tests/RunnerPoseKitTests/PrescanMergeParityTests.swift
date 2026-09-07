import XCTest
@testable import RunnerPoseKit

/// S0 `mergeHitFrames` must agree with the Python source of truth
/// (`scripts/prescan_merge.py` `PARITY_CASES`). Keep both tables identical.
final class PrescanMergeParityTests: XCTestCase {

    struct Case {
        let hits: [Int]
        let total: Int
        let stride: Int
        let buffer: Int
        let gap: Int
        let expected: [(Int, Int)]
    }

    let cases: [Case] = [
        .init(hits: [], total: 100, stride: 8, buffer: 15, gap: 15, expected: []),
        .init(hits: [50], total: 100, stride: 8, buffer: 15, gap: 15, expected: [(35, 72)]),
        .init(hits: [10, 12, 14, 16], total: 200, stride: 8, buffer: 8, gap: 8, expected: [(2, 31)]),
        .init(hits: [10, 40], total: 200, stride: 8, buffer: 8, gap: 8, expected: [(2, 25), (32, 55)]),
        .init(hits: [10, 20], total: 200, stride: 8, buffer: 8, gap: 15, expected: [(2, 35)]),
        .init(hits: [5, 50], total: 100, stride: 8, buffer: 30, gap: 30, expected: [(0, 87)]),
    ]

    func testMergeMatchesPython() {
        for (i, c) in cases.enumerated() {
            let got = PrescanFilter.mergeHitFrames(
                c.hits, totalFrames: c.total, stride: c.stride,
                bufferFrames: c.buffer, maxGapFrames: c.gap
            ).map { ($0.startFrame, $0.endFrame) }
            XCTAssertEqual(got.count, c.expected.count, "case \(i)")
            for (g, e) in zip(got, c.expected) {
                XCTAssertEqual(g.0, e.0, "case \(i) start")
                XCTAssertEqual(g.1, e.1, "case \(i) end")
            }
        }
    }
}
