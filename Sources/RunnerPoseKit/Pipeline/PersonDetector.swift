import CoreML
import CoreVideo
import Foundation
import Vision

/// One person box from the detector, in **source-frame pixels**.
struct Detection {
    var box: BBox
    var confidence: Double
}

/// Upstream person detector for S0 (prescan) and S2 (per-frame gate).
/// One instance is shared by both stages (規劃書 §03 / §04).
protocol PersonDetector: AnyObject {
    /// Detect people in `frame`. `frameSize` is the source pixel size.
    /// Implementations run at `config.detectorImageSize`; boxes are mapped back to source pixels.
    func detect(_ frame: CVPixelBuffer, frameSize: CGSize) async throws -> [Detection]
    /// Load weights / warm the graph.
    func warmUp() async
}

extension PersonDetector {
    /// Pick the runner: the qualifying box nearest a hint (previous tracked centre),
    /// else the tallest. `nil` if none qualifies (S2 gate fails / prescan miss).
    func pickRunner(
        _ detections: [Detection],
        near hint: BBox?,
        config: Config
    ) -> Detection? {
        let qualifying = detections.filter {
            $0.confidence >= config.detectorConf && $0.box.height >= config.minBoxHeight
        }
        guard !qualifying.isEmpty else { return nil }
        if let hint {
            return qualifying.max { $0.box.iou(hint) < $1.box.iou(hint) }
                ?? qualifying.min {
                    hypot($0.box.centerX - hint.centerX, $0.box.centerY - hint.centerY)
                    < hypot($1.box.centerX - hint.centerX, $1.box.centerY - hint.centerY)
                }
        }
        return qualifying.max { $0.box.height < $1.box.height }
    }
}

// MARK: - YOLO26 (Core ML, via UltralyticsYOLO)

/// Wraps the UltralyticsYOLO detector around a bundled `yolo26<scale>.mlpackage`.
///
/// TODO(mac): wire to the real `UltralyticsYOLO` API. As of v8.3.x the entry point is
/// roughly `YOLO(<name>, task: .detect)` returning boxes in letterboxed 640 space;
/// map back to source pixels here. `config.computeUnits` must reach the underlying
/// `MLModelConfiguration` (規劃書 §02 已知文件錯誤: use `.cpuAndNeuralEngine`, not `.all`).
final class YOLO26Detector: PersonDetector {
    private let scale: DetectorModel
    private let config: Config
    // private var yolo: YOLO?   // from UltralyticsYOLO

    init(scale: DetectorModel, config: Config) throws {
        guard let name = scale.mlpackageName, ModelResources.exists(name)
        else { throw RunnerPoseError.modelResourceMissing((scale.mlpackageName ?? scale.rawValue) + ".mlpackage") }
        self.scale = scale
        self.config = config
    }

    func warmUp() async {
        // TODO(mac): load YOLO + run one dummy 640×640 predict.
    }

    func detect(_ frame: CVPixelBuffer, frameSize: CGSize) async throws -> [Detection] {
        // TODO(mac): letterbox `frame` to config.detectorImageSize, run YOLO,
        // keep class 0 (person), un-letterbox boxes into source pixels.
        _ = (frame, frameSize)
        throw RunnerPoseError.detectorUnavailable(scale)
    }
}

// MARK: - Apple Vision (optional comparison; free, no AGPL)

@available(iOS 15.0, macOS 12.0, *)
final class VisionHumanDetector: PersonDetector {
    private let config: Config
    init(config: Config) { self.config = config }

    func warmUp() async {}

    func detect(_ frame: CVPixelBuffer, frameSize: CGSize) async throws -> [Detection] {
        try await withCheckedThrowingContinuation { cont in
            let request = VNDetectHumanRectanglesRequest { req, err in
                if let err { cont.resume(throwing: err); return }
                let obs = (req.results as? [VNHumanObservation]) ?? []
                let dets: [Detection] = obs.map { o in
                    // Vision boxes: normalised, origin bottom-left. Convert to top-left pixels.
                    let r = VNImageRectForNormalizedRect(o.boundingBox,
                                                         Int(frameSize.width), Int(frameSize.height))
                    let box = BBox(x1: r.minX,
                                   y1: frameSize.height - r.maxY,
                                   x2: r.maxX,
                                   y2: frameSize.height - r.minY)
                    return Detection(box: box, confidence: Double(o.confidence))
                }
                cont.resume(returning: dets)
            }
            request.upperBodyOnly = false
            let handler = VNImageRequestHandler(cvPixelBuffer: frame, options: [:])
            do { try handler.perform([request]) } catch { cont.resume(throwing: error) }
        }
    }
}

// MARK: - factory

enum DetectorFactory {
    static func make(_ config: Config) throws -> PersonDetector {
        switch config.detectorModel {
        case .visionHuman:
            if #available(iOS 15.0, macOS 12.0, *) { return VisionHumanDetector(config: config) }
            throw RunnerPoseError.detectorUnavailable(.visionHuman)
        default:
            return try YOLO26Detector(scale: config.detectorModel, config: config)
        }
    }
}
