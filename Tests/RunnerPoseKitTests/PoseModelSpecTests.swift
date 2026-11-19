import XCTest
@testable import RunnerPoseKit

/// Pose model specs (Resources/PoseModels/, copied from the pipeline by
/// scripts/pose_models/sync_pose_specs.py). TODO(mac): first run on the Mac.
final class PoseModelSpecTests: XCTestCase {

    func testBundledSpecsLoadAndIncludeTheDefaultModel() throws {
        let specs = try PoseModelCatalog.all()
        XCTAssertTrue(specs.contains { $0.id == PoseModelCatalog.defaultModelID })
    }

    /// The spec must describe what HRNetRunner / CropWarp / HeatmapDecoder actually do, until
    /// they read these values from the spec themselves.
    func testHRNetSpecMatchesTheRunner() throws {
        let spec = try PoseModelCatalog.runnableSpec(named: "hrnet")
        let config = Config()
        XCTAssertEqual(spec.id, HRNetRunner.modelID)
        XCTAssertEqual(spec.input.width, config.hrnetInputWidth)
        XCTAssertEqual(spec.input.height, config.hrnetInputHeight)
        XCTAssertEqual(spec.output.kind, .heatmap)
        XCTAssertEqual(spec.output.heatmap?.width, config.heatmapWidth)
        XCTAssertEqual(spec.output.heatmap?.height, config.heatmapHeight)
        XCTAssertEqual(spec.decoder, .darkHeatmap)
        XCTAssertEqual(spec.coreml?.inputName, "person_crop")
        XCTAssertEqual(spec.coreml?.outputNames["heatmaps"], "heatmaps")
        XCTAssertEqual(spec.coreml?.resourceName, HRNetRunner.resourceName)
        XCTAssertEqual(spec.keypoints.names ?? [], JointName.canonicalNames)
        XCTAssertTrue(spec.missingJoints.isEmpty)
        XCTAssertNoThrow(try spec.require(JointName.longJumpJoints, for: "the long-jump analysis"))
    }

    func testCanonicalNamesFollowJointNameOrder() {
        XCTAssertEqual(JointName.canonicalNames.count, JointName.count)
        XCTAssertEqual(JointName.leftHeel.canonicalName, "left_heel")
        XCTAssertEqual(JointName.rightHeel.canonicalName, "right_heel")
    }

    func testBodyOnlySimCCSpecReportsMissingFeet() throws {
        let spec = try decode(Self.bodyOnlySimCC)
        try spec.validate()
        XCTAssertEqual(
            Set(spec.missingJoints),
            [.leftBigToe, .leftSmallToe, .leftHeel, .rightBigToe, .rightSmallToe, .rightHeel]
        )
        XCTAssertThrowsError(try spec.require(JointName.longJumpJoints, for: "the long-jump analysis"))
    }

    func testDecoderThatCannotReadTheOutputIsRejected() throws {
        let spec = try decode(Self.bodyOnlySimCC.replacingOccurrences(of: "\"simcc_argmax\"", with: "\"dark_heatmap\""))
        XCTAssertThrowsError(try spec.validate())
    }

    func testUnknownModelNameIsReported() {
        XCTAssertThrowsError(try PoseModelCatalog.spec(named: "no_such_model")) { error in
            guard case PoseModelSpecError.notFound = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testCanonicalMappingFillsMissingJointsWithNaN() throws {
        let spec = try decode(Self.bodyOnlySimCC)
        let native = (0..<17).map { NativeKeypoint(x: Double($0), y: Double($0) * 2, score: 0.9) }
        let joints = CanonicalJoints.map(native, spec: spec)
        XCTAssertEqual(joints.count, JointName.count)
        XCTAssertEqual(joints[JointName.leftAnkle.rawValue].x, 15)
        XCTAssertTrue(joints[JointName.leftHeel.rawValue].x.isNaN)
        XCTAssertEqual(joints[JointName.leftHeel.rawValue].score, 0)
    }

    private func decode(_ json: String) throws -> PoseModelSpec {
        try JSONDecoder().decode(PoseModelSpec.self, from: Data(json.utf8))
    }

    /// A COCO-17 SimCC model: body joints only.
    static let bodyOnlySimCC = """
    {
      "spec_version": 1,
      "id": "simcc_body_only",
      "status": "experimental",
      "keypoints": {
        "count": 17,
        "to_canonical": [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,null,null,null,null,null,null]
      },
      "input": {"width": 192, "height": 256, "color_order": "RGB"},
      "output": {"kind": "simcc", "simcc": {"split_ratio": 2.0}},
      "decoder": "simcc_argmax",
      "server": null,
      "coreml": {
        "package": "SimCCBody.mlpackage",
        "input_name": "person_crop",
        "output_names": {"simcc_x": "simcc_x", "simcc_y": "simcc_y"}
      }
    }
    """
}
