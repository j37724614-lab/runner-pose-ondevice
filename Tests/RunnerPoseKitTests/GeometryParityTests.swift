import XCTest
import simd
@testable import RunnerPoseKit

/// `Geometry.boxToCenterScale` + `Geometry.affineTransform` must reproduce the
/// pipeline's `box_to_center_scale` / `get_affine_transform` exactly (規劃書 §05 P1).
final class GeometryParityTests: XCTestCase {

    func testCenterScaleAndAffineMatchFixtures() throws {
        if skipIfNoFixtures() { return }
        for name in Fixtures.names() {
            let f = try Fixtures.geometry(name)
            let box = BBox(x1: f.bbox[0], y1: f.bbox[1], x2: f.bbox[2], y2: f.bbox[3])

            let (center, scale) = Geometry.boxToCenterScale(
                box: box, frameWidth: f.frame_size[0], frameHeight: f.frame_size[1]
            )
            XCTAssertEqual(center.x, f.center[0], accuracy: 1e-4, "\(name) center.x")
            XCTAssertEqual(center.y, f.center[1], accuracy: 1e-4, "\(name) center.y")
            XCTAssertEqual(scale.x, f.scale[0], accuracy: 1e-5, "\(name) scale.x")
            XCTAssertEqual(scale.y, f.scale[1], accuracy: 1e-5, "\(name) scale.y")

            let fwd = Geometry.affineTransform(
                center: center, scale: scale,
                outputSize: SIMD2(288, 384), inverse: false
            )
            assertAffine(fwd, f.forward_affine_crop, "\(name) forward")

            let inv = Geometry.affineTransform(
                center: center, scale: scale,
                outputSize: SIMD2(72, 96), inverse: true
            )
            assertAffine(inv, f.inverse_affine_heatmap, "\(name) inverse-heatmap")
        }
    }

    private func assertAffine(_ a: Geometry.Affine, _ expected: [Double], _ label: String) {
        // expected order: a b tx c d ty
        XCTAssertEqual(a.a, expected[0], accuracy: 1e-4, "\(label) a")
        XCTAssertEqual(a.b, expected[1], accuracy: 1e-4, "\(label) b")
        XCTAssertEqual(a.tx, expected[2], accuracy: 1e-3, "\(label) tx")
        XCTAssertEqual(a.c, expected[3], accuracy: 1e-4, "\(label) c")
        XCTAssertEqual(a.d, expected[4], accuracy: 1e-4, "\(label) d")
        XCTAssertEqual(a.ty, expected[5], accuracy: 1e-3, "\(label) ty")
    }
}
