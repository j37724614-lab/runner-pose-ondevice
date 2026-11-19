import CoreML
import Foundation

/// Heatmap models (HRNet ...): the existing DarkPose `HeatmapDecoder`.
///
/// `HeatmapDecoder` still reads the heatmap size from `Config` (72 × 96) and always returns the
/// 23 HRNet joints; that matches every heatmap spec we ship. TODO(mac): when a heatmap model
/// with another size or joint count arrives, pass `spec.output.heatmap` and
/// `spec.keypoints.count` into `HeatmapDecoder` instead.
struct DarkHeatmapKeypointDecoder: KeypointDecoder {
    let decoder: HeatmapDecoder

    func decode(_ output: PoseModelOutput, center: SIMD2<Double>, scale: SIMD2<Double>) throws -> [NativeKeypoint] {
        guard case .heatmap(let heatmap) = output else {
            throw KeypointDecoderError.wrongOutputKind(expected: .heatmap)
        }
        return decoder.decode(heatmap: heatmap, center: center, scale: scale).map {
            NativeKeypoint(x: $0.x, y: $0.y, score: $0.score)
        }
    }
}

/// SimCC models (RTMPose ...): per keypoint, one classification vector over x and one over y,
/// `splitRatio` times finer than the input crop.
///
/// Must match the pipeline's reference decoder (runner-analysis-pipeline
/// `core/pose_models/simcc.py`, after MMPose `get_simcc_maximum`):
///   - location = argmax / splitRatio, in crop pixels;
///   - score = the smaller of the two maxima;
///   - score <= 0 -> not found.
/// `SimCCDecoderTests` checks it against fixtures that script writes.
struct SimCCKeypointDecoder: KeypointDecoder {
    let splitRatio: Double
    /// Model input (crop) size: the space SimCC coordinates live in before the inverse affine.
    let inputWidth: Int
    let inputHeight: Int

    init(spec: PoseModelSpec) throws {
        guard spec.output.kind == .simcc, let simcc = spec.output.simcc else {
            throw KeypointDecoderError.wrongOutputKind(expected: .simcc)
        }
        splitRatio = simcc.splitRatio
        inputWidth = spec.input.width
        inputHeight = spec.input.height
    }

    func decode(_ output: PoseModelOutput, center: SIMD2<Double>, scale: SIMD2<Double>) throws -> [NativeKeypoint] {
        guard case .simcc(let x, let y) = output else {
            throw KeypointDecoderError.wrongOutputKind(expected: .simcc)
        }
        let rowsX = try Self.rows(x, name: "simcc_x")
        let rowsY = try Self.rows(y, name: "simcc_y")
        guard rowsX.count == rowsY.count else {
            throw KeypointDecoderError.shapeMismatch("simcc_x has \(rowsX.count) keypoints, simcc_y \(rowsY.count)")
        }
        // TODO(mac): check the crop geometry (aspect ratio, bbox padding) matches how the model
        // was trained before trusting frame coordinates; see scripts/pose_models/README.md.
        let toFrame = Geometry.affineTransform(
            center: center,
            scale: scale,
            outputSize: SIMD2(Double(inputWidth), Double(inputHeight)),
            inverse: true
        )
        return Self.decodeCrop(rowsX: rowsX, rowsY: rowsY, splitRatio: splitRatio).map { point, score in
            guard score > 0 else { return NativeKeypoint(x: .nan, y: .nan, score: score) }
            let frame = toFrame.apply(point)
            return NativeKeypoint(x: frame.x, y: frame.y, score: score)
        }
    }

    /// Crop-pixel locations and scores; `(-1, -1)` for keypoints with score <= 0.
    /// Pure arithmetic, so the parity test can feed it the reference fixtures directly.
    static func decodeCrop(
        rowsX: [[Double]], rowsY: [[Double]], splitRatio: Double
    ) -> [(SIMD2<Double>, Double)] {
        zip(rowsX, rowsY).map { vx, vy in
            let (ix, mx) = argmax(vx)
            let (iy, my) = argmax(vy)
            let score = min(mx, my)
            guard score > 0 else { return (SIMD2<Double>(-1, -1), score) }
            return (SIMD2<Double>(Double(ix) / splitRatio, Double(iy) / splitRatio), score)
        }
    }

    /// First index of the maximum, like numpy.argmax.
    static func argmax(_ values: [Double]) -> (Int, Double) {
        var best = 0
        var bestValue = -Double.infinity
        for (i, v) in values.enumerated() where v > bestValue {
            best = i
            bestValue = v
        }
        return (best, bestValue)
    }

    /// [1, K, N] or [K, N] MultiArray -> K rows of N values, read through the array's strides.
    /// TODO(mac): replace with a vDSP read of the Float16/Float32 backing if profiling shows it
    /// matters (K × N is ~133 × 768 for RTMPose wholebody).
    static func rows(_ array: MLMultiArray, name: String) throws -> [[Double]] {
        let shape = array.shape.map(\.intValue)
        let k: Int
        let n: Int
        let batched: Bool
        if shape.count == 3, shape[0] == 1 {
            k = shape[1]
            n = shape[2]
            batched = true
        } else if shape.count == 2 {
            k = shape[0]
            n = shape[1]
            batched = false
        } else {
            throw KeypointDecoderError.shapeMismatch("\(name) shape \(shape)")
        }
        return (0..<k).map { row in
            (0..<n).map { col in
                let index: [NSNumber] = batched
                    ? [0, NSNumber(value: row), NSNumber(value: col)]
                    : [NSNumber(value: row), NSNumber(value: col)]
                return array[index].doubleValue
            }
        }
    }
}
