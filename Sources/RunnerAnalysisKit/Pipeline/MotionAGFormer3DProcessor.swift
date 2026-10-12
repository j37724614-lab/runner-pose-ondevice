import CoreML
import Foundation

public protocol Analysis3DProcessing: Sendable {
    func process(pose2D: Analysis2DResult, request: AnalysisRequest) async throws -> Analysis3DResult
}

/// Internal model seam: production uses Core ML and tests use a deterministic
/// in-memory predictor. Callers still only know RunnerAnalysisEngine.
public protocol MotionAGFormerPredicting: Sendable {
    func predict(input: [Float]) async throws -> [Float]
}

public actor CoreMLMotionAGFormerPredictor: MotionAGFormerPredicting {
    public static let resourceName = "MotionAGFormerLarge243"
    public static let elementCount = 1 * 243 * 17 * 3

    private let model: MLModel

    public init(modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let compiledURL: URL
        if modelURL.pathExtension == "mlmodelc" {
            compiledURL = modelURL
        } else {
            compiledURL = try MLModel.compileModel(at: modelURL)
        }
        model = try MLModel(contentsOf: compiledURL, configuration: configuration)
    }

    public static func bundled(computeUnits: MLComputeUnits = .all) throws -> CoreMLMotionAGFormerPredictor {
        try CoreMLMotionAGFormerPredictor(
            modelURL: MotionAGFormerResources.locate(Self.resourceName),
            computeUnits: computeUnits
        )
    }

    public static var isBundled: Bool {
        MotionAGFormerResources.exists(Self.resourceName)
    }

    public func predict(input values: [Float]) async throws -> [Float] {
        guard values.count == Self.elementCount else {
            throw RunnerAnalysisError.processingFailed(
                "MotionAGFormer expected \(Self.elementCount) input values, got \(values.count)."
            )
        }
        let input = try MLMultiArray(
            shape: [
                NSNumber(value: 1), NSNumber(value: 243),
                NSNumber(value: 17), NSNumber(value: 3),
            ],
            dataType: .float32
        )
        for (index, value) in values.enumerated() {
            input[index] = NSNumber(value: value)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "pose2d_input": MLFeatureValue(multiArray: input),
        ])
        let prediction = try model.prediction(from: provider)
        guard let output = prediction.featureValue(for: "pose3d_output")?.multiArrayValue else {
            throw RunnerAnalysisError.processingFailed(
                "MotionAGFormer output pose3d_output is missing."
            )
        }
        guard output.count == Self.elementCount else {
            throw RunnerAnalysisError.processingFailed(
                "MotionAGFormer expected \(Self.elementCount) output values, got \(output.count)."
            )
        }
        return (0..<output.count).map { output[$0].floatValue }
    }
}

/// WholeBody23 -> H36M17 -> 243-frame MotionAGFormer -> angles.
/// Frame identity, camera identity and padding stay hidden inside this deep
/// module and emerge as explicit Pose3DFrame values.
public actor MotionAGFormer3DProcessor: Analysis3DProcessing {
    static let clipLength = 243
    static let jointCount = 17
    static let valueCountPerFrame = jointCount * 3

    private let predictor: any MotionAGFormerPredicting

    public init(predictor: any MotionAGFormerPredicting) {
        self.predictor = predictor
    }

    public func process(pose2D: Analysis2DResult, request: AnalysisRequest) async throws -> Analysis3DResult {
        let startedAt = Date()
        var outputFrames: [Pose3DFrame] = []

        for camera in request.cameras.sorted(by: { $0.cameraIndex < $1.cameraIndex }) {
            try Task.checkCancellation()
            let source = pose2D.frames
                .filter { $0.cameraIndex == camera.cameraIndex && $0.valid && $0.joints.count == 23 }
                .sorted { $0.sourceFrame < $1.sourceFrame }
            guard !source.isEmpty else { continue }

            let h36m = source.map(Self.convertWholeBody23ToH36M17)
            for window in Self.windows(frames: h36m) {
                try Task.checkCancellation()
                let normalized = Self.normalizedInput(
                    window.padded,
                    width: camera.video.width,
                    height: camera.video.height
                )
                let flipped = Self.flip(normalized)
                async let regularPrediction = predictor.predict(input: normalized)
                async let flippedPrediction = predictor.predict(input: flipped)
                let regular = try await regularPrediction
                let unflipped = Self.unflip(try await flippedPrediction)
                let averaged = zip(regular, unflipped).map { ($0 + $1) * 0.5 }

                for (sourceOffset, predictionOffset) in window.outputPositions.enumerated() {
                    let metadata = window.original[sourceOffset].metadata
                    let base = predictionOffset * Self.valueCountPerFrame
                    let joints = (0..<Self.jointCount).map { jointIndex in
                        let offset = base + jointIndex * 3
                        return Pose3DJoint(
                            x: Double(averaged[offset]),
                            y: Double(averaged[offset + 1]),
                            z: Double(averaged[offset + 2])
                        )
                    }
                    outputFrames.append(Pose3DFrame(
                        cameraIndex: metadata.cameraIndex,
                        sourceFrame: metadata.sourceFrame,
                        timestampSeconds: metadata.timestampSeconds,
                        joints: joints
                    ))
                }
            }
        }

        guard !outputFrames.isEmpty else {
            throw RunnerAnalysisError.processingFailed(
                "MotionAGFormer received no valid WholeBody23 frames."
            )
        }
        outputFrames.sort {
            $0.cameraIndex == $1.cameraIndex
                ? $0.sourceFrame < $1.sourceFrame
                : $0.cameraIndex < $1.cameraIndex
        }
        let fpsByCamera = Dictionary(uniqueKeysWithValues: request.cameras.map {
            ($0.cameraIndex, $0.video.fps)
        })
        let angles = AnalysisAngleCalculator.compute(
            frames: outputFrames,
            fpsByCamera: fpsByCamera
        )
        return Analysis3DResult(
            frames: outputFrames,
            angles: angles,
            durationSeconds: Date().timeIntervalSince(startedAt),
            warnings: [
                "Leg-identity DP remains pending Step 18 and can affect left/right 3D semantics.",
            ]
        )
    }
}

extension MotionAGFormer3DProcessor {
    struct FrameMetadata: Sendable, Equatable {
        var cameraIndex: Int
        var sourceFrame: Int
        var timestampSeconds: Double
    }

    struct H36M2DFrame: Sendable, Equatable {
        var metadata: FrameMetadata
        /// 17 joints, each x/y/confidence.
        var values: [Float]
    }

    struct Window: Sendable, Equatable {
        var original: [H36M2DFrame]
        var padded: [H36M2DFrame]
        /// For each original frame, the first corresponding output position in
        /// the padded 243-frame prediction (np.unique(..., return_index=True)).
        var outputPositions: [Int]
    }

    static func convertWholeBody23ToH36M17(_ frame: Pose2DFrame) -> H36M2DFrame {
        precondition(frame.joints.count == 23)
        var output = Array(repeating: Float(0), count: valueCountPerFrame)

        func point(_ index: Int) -> (Float, Float, Float) {
            let joint = frame.joints[index]
            return (Float(joint.x), Float(joint.y), Float(joint.score))
        }
        func set(_ index: Int, _ value: (Float, Float, Float)) {
            output[index * 3] = value.0
            output[index * 3 + 1] = value.1
            output[index * 3 + 2] = value.2
        }
        func mean(_ indices: [Int]) -> (Float, Float, Float) {
            let points = indices.map(point)
            let count = Float(points.count)
            return (
                points.reduce(0) { $0 + $1.0 } / count,
                points.reduce(0) { $0 + $1.1 } / count,
                points.reduce(0) { $0 + $1.2 } / count
            )
        }

        let shoulder = mean([5, 6])
        let pelvis = mean([11, 12])
        let torsoMean = mean([5, 6, 11, 12])
        let nose = point(0)
        let face = mean([1, 2, 3, 4])

        set(0, pelvis)
        set(1, point(12))
        set(2, point(14))
        set(3, point(16))
        set(4, point(11))
        set(5, point(13))
        set(6, point(15))
        set(8, (
            shoulder.0 + (nose.0 - shoulder.0) / 3,
            shoulder.1 + (nose.1 - shoulder.1) / 3,
            shoulder.2
        ))
        let thorax = (output[24], output[25], output[26])
        set(7, (
            torsoMean.0 + 2 * (torsoMean.0 - (pelvis.0 + thorax.0) / 2),
            torsoMean.1,
            (pelvis.2 + shoulder.2) / 2
        ))
        set(9, (
            nose.0 - (nose.0 - shoulder.0) / 4,
            nose.1 - (nose.1 - shoulder.1) / 4,
            nose.2
        ))
        set(10, (
            face.0,
            point(1).1 + point(2).1 - nose.1,
            face.2
        ))
        set(11, point(5))
        set(12, point(7))
        set(13, point(9))
        set(14, point(6))
        set(15, point(8))
        set(16, point(10))

        return H36M2DFrame(
            metadata: FrameMetadata(
                cameraIndex: frame.cameraIndex,
                sourceFrame: frame.sourceFrame,
                timestampSeconds: frame.timestampSeconds
            ),
            values: output
        )
    }

    static func windows(frames: [H36M2DFrame]) -> [Window] {
        guard !frames.isEmpty else { return [] }
        var result: [Window] = []
        var start = 0
        while start < frames.count {
            let end = min(start + clipLength, frames.count)
            let original = Array(frames[start..<end])
            if original.count == clipLength {
                result.append(Window(
                    original: original,
                    padded: original,
                    outputPositions: Array(0..<clipLength)
                ))
            } else {
                let indices = (0..<clipLength).map { position in
                    min(original.count - 1, Int(floor(Double(position * original.count) / Double(clipLength))))
                }
                var firstPosition = Array(repeating: -1, count: original.count)
                for (position, index) in indices.enumerated() where firstPosition[index] == -1 {
                    firstPosition[index] = position
                }
                result.append(Window(
                    original: original,
                    padded: indices.map { original[$0] },
                    outputPositions: firstPosition
                ))
            }
            start = end
        }
        return result
    }

    static func normalizedInput(_ frames: [H36M2DFrame], width: Int, height: Int) -> [Float] {
        precondition(frames.count == clipLength)
        let safeWidth = Float(max(width, 1))
        let aspectHeight = Float(max(height, 1)) / safeWidth
        var result: [Float] = []
        result.reserveCapacity(frames.reduce(0) { $0 + $1.values.count })
        for frame in frames {
            for offset in stride(from: 0, to: frame.values.count, by: 3) {
                let normalizedX = frame.values[offset] / safeWidth * 2 - 1
                let normalizedY = frame.values[offset + 1] / safeWidth * 2 - aspectHeight
                result.append(normalizedX)
                result.append(normalizedY)
                result.append(frame.values[offset + 2])
            }
        }
        return result
    }

    static func flip(_ values: [Float]) -> [Float] {
        transformFlip(values)
    }

    static func unflip(_ values: [Float]) -> [Float] {
        transformFlip(values)
    }

    private static func transformFlip(_ values: [Float]) -> [Float] {
        precondition(values.count == CoreMLMotionAGFormerPredictor.elementCount)
        let swaps = [(1, 4), (2, 5), (3, 6), (14, 11), (15, 12), (16, 13)]
        var result = values
        for frame in 0..<clipLength {
            let frameBase = frame * valueCountPerFrame
            for joint in 0..<jointCount {
                result[frameBase + joint * 3] = -values[frameBase + joint * 3]
            }
            for (left, right) in swaps {
                for coordinate in 0..<3 {
                    result[frameBase + left * 3 + coordinate] = coordinate == 0
                        ? -values[frameBase + right * 3 + coordinate]
                        : values[frameBase + right * 3 + coordinate]
                    result[frameBase + right * 3 + coordinate] = coordinate == 0
                        ? -values[frameBase + left * 3 + coordinate]
                        : values[frameBase + left * 3 + coordinate]
                }
            }
        }
        return result
    }
}

enum AnalysisAngleCalculator {
    static func compute(
        frames: [Pose3DFrame],
        fpsByCamera: [Int: Double] = [:]
    ) -> [AnalysisAngleFrame] {
        var result = frames.map { frame in
            let p = frame.joints
            precondition(p.count == 17)
            let rawValues = [
                "left_knee_angle": angle(p[4], p[5], p[6]),
                "left_hip_angle": angle(p[11], p[4], p[5]),
                "right_knee_angle": angle(p[1], p[2], p[3]),
                "right_hip_angle": angle(p[14], p[1], p[2]),
                "left_arm_torso_angle": angle(p[4], p[11], p[12]),
                "left_elbow_flexion_angle": angle(p[13], p[12], p[11]),
                "right_arm_torso_angle": angle(p[1], p[14], p[15]),
                "right_elbow_flexion_angle": angle(p[16], p[15], p[14]),
                "left_shoulder_flexion": angle(p[0], p[8], p[12]),
                "right_shoulder_flexion": angle(p[0], p[8], p[15]),
                "pelvis_torso_angle": angleBetween(
                    (0.0, -1.0, 0.0),
                    (p[8].x - p[0].x, p[8].y - p[0].y, p[8].z - p[0].z)
                ),
            ]
            return AnalysisAngleFrame(
                cameraIndex: frame.cameraIndex,
                sourceFrame: frame.sourceFrame,
                timestampSeconds: frame.timestampSeconds,
                rawValuesDegrees: rawValues,
                valuesDegrees: rawValues
            )
        }
        correctSupplementaryKnees(&result, key: "left_knee_angle")
        correctSupplementaryKnees(&result, key: "right_knee_angle")
        smoothNonKneeAngles(&result, fpsByCamera: fpsByCamera)
        return result
    }

    private static func angle(_ a: Pose3DJoint, _ center: Pose3DJoint, _ b: Pose3DJoint) -> Double {
        angleBetween(
            (a.x - center.x, a.y - center.y, a.z - center.z),
            (b.x - center.x, b.y - center.y, b.z - center.z)
        )
    }

    private static func angleBetween(
        _ lhs: (Double, Double, Double),
        _ rhs: (Double, Double, Double)
    ) -> Double {
        let lhsNorm = sqrt(lhs.0 * lhs.0 + lhs.1 * lhs.1 + lhs.2 * lhs.2)
        let rhsNorm = sqrt(rhs.0 * rhs.0 + rhs.1 * rhs.1 + rhs.2 * rhs.2)
        guard lhsNorm >= 1e-8, rhsNorm >= 1e-8 else { return 0 }
        let cosine = max(-1, min(1, (
            lhs.0 * rhs.0 + lhs.1 * rhs.1 + lhs.2 * rhs.2
        ) / (lhsNorm * rhsNorm)))
        return acos(cosine) * 180 / .pi
    }

    private static func correctSupplementaryKnees(
        _ frames: inout [AnalysisAngleFrame],
        key: String,
        maxDelta: Double = 45,
        improvementMargin: Double = 15
    ) {
        for cameraIndex in Set(frames.map(\.cameraIndex)) {
            let indices = frames.indices.filter { frames[$0].cameraIndex == cameraIndex }
            guard indices.count >= 3 else { continue }
            let raw = indices.map { frames[$0].valuesDegrees[key] ?? 0 }
            var corrected = raw
            for localIndex in raw.indices {
                let neighbors = [localIndex - 2, localIndex - 1, localIndex + 1, localIndex + 2]
                    .filter { raw.indices.contains($0) }
                    .map { corrected[$0] }
                    .sorted()
                guard neighbors.count >= 2 else { continue }
                let reference: Double
                if neighbors.count.isMultiple(of: 2) {
                    let middle = neighbors.count / 2
                    reference = (neighbors[middle - 1] + neighbors[middle]) / 2
                } else {
                    reference = neighbors[neighbors.count / 2]
                }
                let supplementary = 180 - raw[localIndex]
                let rawError = abs(raw[localIndex] - reference)
                let correctedError = abs(supplementary - reference)
                if rawError > maxDelta && correctedError + improvementMargin < rawError {
                    corrected[localIndex] = supplementary
                }
            }
            for (localIndex, globalIndex) in indices.enumerated() {
                frames[globalIndex].valuesDegrees[key] = corrected[localIndex]
            }
        }
    }

    private static func smoothNonKneeAngles(
        _ frames: inout [AnalysisAngleFrame],
        fpsByCamera: [Int: Double]
    ) {
        let excluded = Set(["left_knee_angle", "right_knee_angle"])
        for cameraIndex in Set(frames.map(\.cameraIndex)) {
            let indices = frames.indices.filter { frames[$0].cameraIndex == cameraIndex }
            guard let first = indices.first else { continue }
            let fps = fpsByCamera[cameraIndex] ?? 30
            var window = max(5, Int(fps * 0.22))
            if window.isMultiple(of: 2) { window += 1 }
            guard indices.count >= window else { continue }
            let keys = frames[first].valuesDegrees.keys.filter { !excluded.contains($0) }
            for key in keys {
                let values = indices.map { frames[$0].valuesDegrees[key] ?? 0 }
                let smoothed = savitzkyGolay(values, window: window, polynomialOrder: 3)
                for (localIndex, globalIndex) in indices.enumerated() {
                    frames[globalIndex].valuesDegrees[key] = smoothed[localIndex]
                }
            }
        }
    }

    /// Centered Savitzky-Golay filter with SciPy-compatible mirror padding.
    static func savitzkyGolay(
        _ values: [Double],
        window: Int,
        polynomialOrder: Int
    ) -> [Double] {
        precondition(window > polynomialOrder && !window.isMultiple(of: 2))
        guard values.count >= window else { return values }
        let half = window / 2
        let columns = polynomialOrder + 1
        var normal = Array(repeating: Array(repeating: 0.0, count: columns), count: columns)
        for x in -half...half {
            let powers = (0..<columns).map { pow(Double(x), Double($0)) }
            for row in 0..<columns {
                for column in 0..<columns {
                    normal[row][column] += powers[row] * powers[column]
                }
            }
        }
        guard let inverse = invert(normal) else { return values }
        let coefficients = (-half...half).map { x in
            (0..<columns).reduce(0.0) {
                $0 + inverse[0][$1] * pow(Double(x), Double($1))
            }
        }
        return values.indices.map { index in
            coefficients.enumerated().reduce(0.0) { sum, item in
                let candidate = index + item.offset - half
                let mirrored: Int
                if candidate < 0 {
                    mirrored = -candidate
                } else if candidate >= values.count {
                    mirrored = 2 * values.count - candidate - 2
                } else {
                    mirrored = candidate
                }
                return sum + item.element * values[mirrored]
            }
        }
    }

    private static func invert(_ matrix: [[Double]]) -> [[Double]]? {
        let count = matrix.count
        var augmented = matrix.enumerated().map { row, values in
            values + (0..<count).map { row == $0 ? 1.0 : 0.0 }
        }
        for column in 0..<count {
            guard let pivotRow = (column..<count).max(by: {
                abs(augmented[$0][column]) < abs(augmented[$1][column])
            }), abs(augmented[pivotRow][column]) > 1e-12 else { return nil }
            augmented.swapAt(column, pivotRow)
            let pivot = augmented[column][column]
            for item in 0..<(2 * count) { augmented[column][item] /= pivot }
            for row in 0..<count where row != column {
                let factor = augmented[row][column]
                for item in 0..<(2 * count) {
                    augmented[row][item] -= factor * augmented[column][item]
                }
            }
        }
        return augmented.map { Array($0[count..<(2 * count)]) }
    }
}

private enum MotionAGFormerResources {
    private final class BundleToken {}

    static func locate(_ name: String) throws -> URL {
        for bundle in candidateBundles {
            if let compiled = bundle.url(forResource: name, withExtension: "mlmodelc") {
                return compiled
            }
            if let package = bundle.url(forResource: name, withExtension: "mlpackage") {
                return package
            }
            if let model = bundle.url(forResource: name, withExtension: "mlmodel") {
                return model
            }
        }
        throw RunnerAnalysisError.processingFailed("Missing \(name).mlpackage.")
    }

    static func exists(_ name: String) -> Bool {
        (try? locate(name)) != nil
    }

    private static var candidateBundles: [Bundle] {
        var bundles: [Bundle] = []
#if SWIFT_PACKAGE
        bundles.append(.module)
#endif
        let frameworkBundle = Bundle(for: BundleToken.self)
        if let resourceURL = frameworkBundle.url(
            forResource: "RunnerAnalysisKitResources",
            withExtension: "bundle"
        ), let resourceBundle = Bundle(url: resourceURL) {
            bundles.append(resourceBundle)
        }
        bundles.append(frameworkBundle)
        bundles.append(.main)
        return bundles
    }
}
