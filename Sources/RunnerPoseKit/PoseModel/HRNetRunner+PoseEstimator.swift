import CoreVideo
import Foundation

/// HRNet is the first `PoseEstimator`. Its spec (`Resources/PoseModels/hrnet_w48_wholebody23.json`)
/// must agree with the constants `HRNetRunner`, `CropWarp` and `HeatmapDecoder` still use;
/// `PoseModelSpecTests.testHRNetSpecMatchesTheRunner` checks that.
extension HRNetRunner: PoseEstimator {
    static let modelID = "hrnet_w48_wholebody23"

    var modelID: String { Self.modelID }

    func predictOutput(crop: CVPixelBuffer) throws -> PoseModelOutput {
        .heatmap(try predict(crop: crop))
    }
}
