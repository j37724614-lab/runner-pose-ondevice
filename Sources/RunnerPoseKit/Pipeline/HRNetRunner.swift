import CoreML
import CoreVideo
import Foundation

/// S4 — the HRNet-W48 wholebody-23 Core ML model.
///
/// Contract (規劃書 §02, `HRNetRunnerWholeBody23.conversion.json`):
///   input  `person_crop`  Image, RGB, 288 (w) × 384 (h), values 0…255, normalisation baked in
///   output `heatmaps`     MultiArray [1, 23, 96, 72]
///
/// Optimisations baked in here (規劃書 §04 模型層):
///   - `.mlmodelc` compiled once, compiled URL cached on disk
///   - `computeUnits` from `Config` (default `.cpuAndNeuralEngine`)
///   - `MLPredictionOptions.outputBackings` reuses one heatmap buffer across frames
///   - `warmUp()` runs one dummy predict so the first real frame is not an outlier
final class HRNetRunner {
    let config: Config
    private let model: MLModel
    private let heatmapShape: [NSNumber]
    private var reusableOutput: MLMultiArray
    private(set) var loadSeconds: TimeInterval = 0

    /// Basename of the bundled model (no extension).
    static let resourceName = "HRNetRunnerWholeBody23"

    init(config: Config) throws {
        self.config = config
        let t0 = Date()

        let located = try ModelResources.locate(Self.resourceName)

        let mlc = MLModelConfiguration()
        mlc.computeUnits = config.computeUnits

        do {
            let compiledURL = located.needsCompile
                ? try Self.cachedCompile(of: located.url)
                : located.url
            self.model = try MLModel(contentsOf: compiledURL, configuration: mlc)
        } catch {
            throw RunnerPoseError.modelLoadFailed(Self.resourceName, underlying: error)
        }

        self.heatmapShape = [NSNumber(value: 1),
                             NSNumber(value: JointName.count),
                             NSNumber(value: config.heatmapHeight),
                             NSNumber(value: config.heatmapWidth)]
        self.reusableOutput = try MLMultiArray(shape: heatmapShape, dataType: .float32)
        self.loadSeconds = Date().timeIntervalSince(t0)
    }

    /// Compile `.mlpackage` -> `.mlmodelc` once; reuse the compiled artifact on later launches.
    /// (規劃書 §04: cold-start compile is hundreds of ms … seconds.)
    private static func cachedCompile(of packageURL: URL) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let cached = caches.appendingPathComponent("\(resourceName).mlmodelc", isDirectory: true)
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        let compiled = try MLModel.compileModel(at: packageURL)
        try? FileManager.default.removeItem(at: cached)
        try FileManager.default.copyItem(at: compiled, to: cached)
        return cached
    }

    func warmUp() async {
        guard let dummy = try? Self.blankCrop(width: config.hrnetInputWidth, height: config.hrnetInputHeight) else { return }
        _ = try? predict(crop: dummy)
    }

    /// Run one crop. Returns the (reused) heatmap MultiArray — consume it before the next call.
    func predict(crop: CVPixelBuffer) throws -> MLMultiArray {
        let input = try MLDictionaryFeatureProvider(dictionary: ["person_crop": MLFeatureValue(pixelBuffer: crop)])
        let options = MLPredictionOptions()
        options.outputBackings = ["heatmaps": reusableOutput]

        let out = try model.prediction(from: input, options: options)
        guard let heat = out.featureValue(for: "heatmaps")?.multiArrayValue else {
            throw RunnerPoseError.heatmapShapeMismatch(got: [], expected: heatmapShape.map(\.intValue))
        }
        if heat.shape != heatmapShape {
            throw RunnerPoseError.heatmapShapeMismatch(
                got: heat.shape.map(\.intValue), expected: heatmapShape.map(\.intValue)
            )
        }
        return heat
    }

    private static func blankCrop(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let s = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard s == kCVReturnSuccess, let pb else { throw RunnerPoseError.cropWarpSetup(s) }
        return pb
    }
}
