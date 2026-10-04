import CoreML
import CoreVideo
import Foundation
import Vision

#if canImport(UltralyticsYOLO)
import CoreImage
import UltralyticsYOLO
#endif

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
        frameSize: CGSize,
        config: Config
    ) -> Detection? {
        let qualifying = detections.filter {
            $0.confidence >= config.detectorConf && $0.box.height >= config.minBoxHeight
        }
        guard !qualifying.isEmpty else { return nil }
        if let hint {
            let bestByIoU = qualifying.max { $0.box.iou(hint) < $1.box.iou(hint) }
            let bestIoU = bestByIoU?.box.iou(hint) ?? 0
            if bestIoU >= config.trackerMinIoU {
                return bestByIoU
            }

            guard let bestByDistance = qualifying.min(by: {
                $0.box.centerDistance(to: hint) < $1.box.centerDistance(to: hint)
            }) else {
                return nil
            }

            let frameDiagonal = hypot(frameSize.width, frameSize.height)
            let maxDistance = frameDiagonal * config.trackerMaxCenterDistanceRatio
            return bestByDistance.box.centerDistance(to: hint) <= maxDistance ? bestByDistance : nil
        }
        return qualifying.max { $0.box.height < $1.box.height }
    }
}

// MARK: - YOLO26 (Core ML, via UltralyticsYOLO)

#if canImport(UltralyticsYOLO)
/// Wraps the UltralyticsYOLO detector around a bundled `yolo26<scale>.mlpackage`.
///
final class YOLO26Detector: PersonDetector {
    private let scale: DetectorModel
    private let config: Config
    private let modelPath: String
    private var yolo: YOLO?
    private var loadingYOLO: YOLO?
    private var loadTask: Task<YOLO, Error>?

    init(scale: DetectorModel, config: Config) throws {
        guard let name = scale.mlpackageName else {
            throw RunnerPoseError.detectorUnavailable(scale)
        }
        DebugLog.mark("YOLO init: locating \(name)")
        let located = try ModelResources.locate(name)
        self.scale = scale
        self.config = config
        self.modelPath = located.url.path
        DebugLog.mark("YOLO init: model path \(self.modelPath)")
    }

    func warmUp() async {
        DebugLog.mark("YOLO warmUp: begin")
        _ = try? await loadYOLO()
        DebugLog.mark("YOLO warmUp: end")
    }

    func detect(_ frame: CVPixelBuffer, frameSize: CGSize) async throws -> [Detection] {
        let start = Date()
        DebugLog.mark("YOLO detect: begin frameSize=\(Int(frameSize.width))x\(Int(frameSize.height))")
        let yolo = try await loadYOLO()
        let result = yolo(CIImage(cvPixelBuffer: frame))
        let detections: [Detection] = result.boxes.compactMap { box -> Detection? in
            guard box.index == 0 || box.cls.lowercased() == "person" else { return nil }
            let rect = box.xywh.standardized.intersection(CGRect(origin: .zero, size: frameSize))
            guard rect.width > 0, rect.height > 0 else { return nil }
            return Detection(
                box: BBox(
                    x1: rect.minX,
                    y1: rect.minY,
                    x2: rect.maxX,
                    y2: rect.maxY
                ),
                confidence: Double(box.conf)
            )
        }
        DebugLog.mark(
            "YOLO detect: end boxes=\(result.boxes.count) persons=\(detections.count) ms=\(Int(Date().timeIntervalSince(start) * 1000))"
        )
        return detections
    }

    private func loadYOLO() async throws -> YOLO {
        if let yolo {
            DebugLog.mark("YOLO load: using cached model")
            return yolo
        }
        if let loadTask {
            DebugLog.mark("YOLO load: awaiting existing load task")
            return try await loadTask.value
        }

        let task = Task<YOLO, Error> {
            DebugLog.mark("YOLO load: begin path=\(self.modelPath)")
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<YOLO, Error>) in
                let detector = YOLO(
                    modelPath,
                    task: .detect,
                    useGpu: self.config.computeUnits != .cpuOnly,
                    numItemsThreshold: 30
                ) { result in
                    switch result {
                    case .success(let yolo):
                        DebugLog.mark("YOLO load: success")
                        yolo.setThresholds(confidence: self.config.detectorConf, iou: self.config.detectorIoU)
                        continuation.resume(returning: yolo)
                    case .failure(let error):
                        DebugLog.mark("YOLO load: failure \(error)")
                        continuation.resume(
                            throwing: RunnerPoseError.modelLoadFailed(self.scale.rawValue, underlying: error)
                        )
                    }
                }
                self.loadingYOLO = detector
                detector.setThresholds(confidence: self.config.detectorConf, iou: self.config.detectorIoU)
            }
        }
        loadTask = task

        do {
            let loaded = try await task.value
            yolo = loaded
            loadingYOLO = nil
            loadTask = nil
            DebugLog.mark("YOLO load: cached loaded model")
            return loaded
        } catch {
            loadingYOLO = nil
            loadTask = nil
            DebugLog.mark("YOLO load: threw \(error)")
            throw error
        }
    }
}
#endif

// MARK: - Apple Vision (optional comparison; free, no AGPL)

@available(iOS 15.0, macOS 12.0, *)
final class VisionHumanDetector: PersonDetector {
    private let config: Config
    init(config: Config) { self.config = config }

    func warmUp() async {}

    func detect(_ frame: CVPixelBuffer, frameSize: CGSize) async throws -> [Detection] {
        let start = Date()
        DebugLog.mark("Vision detect: begin frameSize=\(Int(frameSize.width))x\(Int(frameSize.height))")
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[Detection], Error>) in
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
                DebugLog.mark(
                    "Vision detect: end persons=\(dets.count) ms=\(Int(Date().timeIntervalSince(start) * 1000))"
                )
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
            #if canImport(UltralyticsYOLO)
            return try YOLO26Detector(scale: config.detectorModel, config: config)
            #else
            throw RunnerPoseError.detectorUnavailable(config.detectorModel)
            #endif
        }
    }
}
