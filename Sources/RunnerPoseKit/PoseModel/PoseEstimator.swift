import CoreML
import CoreVideo
import Foundation

/// Raw output of one 2D model call, before decoding.
///
/// Estimators may reuse these buffers between calls (`outputBackings`), so a decoder must
/// finish with one output before the estimator runs again.
public enum PoseModelOutput {
    /// [1, K, H, W] heatmaps (HRNet, ViTPose, MogaNet ...).
    case heatmap(MLMultiArray)
    /// [1, K, Wx] and [1, K, Hy] SimCC vectors (RTMPose ...).
    case simcc(x: MLMultiArray, y: MLMultiArray)
}

/// One 2D pose model that turns a person crop into a raw output.
///
/// The crop must be `spec.input.width` × `spec.input.height`, in the model's colour order.
/// Implementations:
///   - `HRNetRunner` (heatmap) — the production model;
///   - a generic Core ML runner driven only by the spec (input/output names from
///     `spec.coreml`) is the next step for RTMPose. TODO(mac): write and test it on device.
protocol PoseEstimator: AnyObject {
    /// Spec id of the model this estimator runs.
    var modelID: String { get }
    var loadSeconds: TimeInterval { get }
    func warmUp() async
    func predictOutput(crop: CVPixelBuffer) throws -> PoseModelOutput
}

/// One decoded keypoint in the model's native order, in original-frame pixels.
/// A keypoint the model did not find has non-finite x/y and score <= 0.
public struct NativeKeypoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var score: Double
}

/// Decodes one `PoseModelOutput` into native keypoints in frame pixels.
///
/// `center` / `scale` are the crop geometry from `Geometry.boxToCenterScale` for this frame.
protocol KeypointDecoder {
    func decode(_ output: PoseModelOutput, center: SIMD2<Double>, scale: SIMD2<Double>) throws -> [NativeKeypoint]
}

enum KeypointDecoderError: Error, CustomStringConvertible {
    case wrongOutputKind(expected: PoseModelSpec.OutputKind)
    case shapeMismatch(String)

    var description: String {
        switch self {
        case .wrongOutputKind(let expected):
            return "decoder expects \(expected.rawValue) output"
        case .shapeMismatch(let detail):
            return "model output shape mismatch: \(detail)"
        }
    }
}

/// Native keypoints -> the canonical 23 `Joint`s every downstream stage reads.
/// Joints the model does not predict come out with NaN coordinates and score 0; callers that
/// need them should have checked `PoseModelSpec.require(_:for:)` before running.
enum CanonicalJoints {
    static func map(_ native: [NativeKeypoint], spec: PoseModelSpec) -> [Joint] {
        zip(JointName.allCases, spec.canonicalIndices).map { name, index in
            guard let index, index < native.count else {
                return Joint(name: name, x: .nan, y: .nan, score: 0)
            }
            let k = native[index]
            return Joint(name: name, x: k.x, y: k.y, score: k.score)
        }
    }
}
