import XCTest
import simd
@testable import RunnerPoseKit

/// `HeatmapDecoder` (get_max_preds + DarkPose blur/Taylor + inverse affine) must match
/// `get_final_preds_dark` to sub-pixel on the fixture heatmaps (規劃書 §05 P1 acceptance).
final class DarkPoseParityTests: XCTestCase {

    /// Acceptance threshold (規劃書 §09 精度: target < 2 px overall; the port itself
    /// must be much tighter than the model error).
    let maxJointErrorPx = 0.5

    func testDecodeMatchesPipeline() throws {
        if skipIfNoFixtures() { return }
        let cfg = Config()
        let decoder = HeatmapDecoder(config: cfg)

        for name in Fixtures.names() {
            let g = try Fixtures.geometry(name)
            let heat = try Fixtures.heatmap(name)
            let expected = try Fixtures.keypoints(name)

            let joints = decoder.decode(
                heatmap: heat,
                center: SIMD2(g.center[0], g.center[1]),
                scale: SIMD2(g.scale[0], g.scale[1])
            )
            XCTAssertEqual(joints.count, 23, "\(name)")

            var worst = 0.0
            for j in 0..<23 {
                let dx = joints[j].x - expected[j][0]
                let dy = joints[j].y - expected[j][1]
                let d = (dx * dx + dy * dy).squareRoot()
                worst = max(worst, d)
                XCTAssertLessThan(
                    d, maxJointErrorPx,
                    "\(name) joint \(JointName(rawValue: j)!) off by \(String(format: "%.3f", d)) px"
                )
            }
            print("✓ \(name): worst joint error \(String(format: "%.3f", worst)) px")
        }
    }

    /// The pieces in isolation, so a failure points at blur vs Taylor vs affine.
    func testTaylorRefineIsBounded() {
        // A clean 2D Gaussian bump: Taylor refine should pull argmax toward the true centre.
        let H = 96, W = 72
        var hm = [Double](repeating: 0, count: H * W)
        let cx = 30.4, cy = 44.7, sigma = 2.0
        for y in 0..<H {
            for x in 0..<W {
                let r2 = pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2)
                hm[y * W + x] = exp(-r2 / (2 * sigma * sigma))
            }
        }
        for i in 0..<hm.count { hm[i] = Foundation.log(min(max(hm[i], 1e-10), 50)) }
        let refined = HeatmapDecoder.darkTaylor(hm, height: H, width: W, coord: SIMD2(30, 45))
        XCTAssertEqual(refined.x, cx, accuracy: 0.15)
        XCTAssertEqual(refined.y, cy, accuracy: 0.15)
    }
}
