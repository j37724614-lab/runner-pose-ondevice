import CoreML

/// Which upstream person detector S0 (prescan) and S2 (per-frame gate) use.
/// They always share **one** instance of whichever is chosen (規劃書 §03 / §04).
///
/// `yolo26{n,s,m,l}` load from `yolo26<scale>.mlpackage` (ultralytics/yolo-ios-app
/// v8.3.0 release: COCO detect, INT8, 640, end2end NMS-free). `yolo26x` is available
/// for completeness but is heavy on ANE. `visionHuman` uses
/// `VNDetectHumanRectanglesRequest` (free, no AGPL) — optional comparison.
public enum DetectorModel: String, CaseIterable, Sendable {
    case yolo26n, yolo26s, yolo26m, yolo26l, yolo26x
    case visionHuman

    /// Resource basename for the `.mlpackage` (nil for `visionHuman`).
    var mlpackageName: String? {
        switch self {
        case .visionHuman: return nil
        default: return rawValue
        }
    }
}

public struct PipelineProgress: Sendable {
    public enum Stage: String, Sendable {
        case initializing
        case warmingUp
        case prescan
        case processing
        case finished
    }

    public var stage: Stage
    public var currentFrame: Int
    public var totalFrames: Int
    public var message: String

    public init(stage: Stage, currentFrame: Int = 0, totalFrames: Int = 0, message: String = "") {
        self.stage = stage
        self.currentFrame = currentFrame
        self.totalFrames = totalFrames
        self.message = message
    }
}

/// All runtime knobs. Defaults reproduce the desktop `prescan_filter_valid_video.py`
/// behaviour; the final `detectorModel` / `detectorCadence` are picked after the
/// §08 先導 sweep in BenchApp.
public struct Config: Sendable {
    // ---- Core ML ----
    public var computeUnits: MLComputeUnits = .cpuAndNeuralEngine

    // ---- detector (S0 + S2) ----
    public var detectorModel: DetectorModel = .yolo26n
    /// Detector inference input long-edge (YOLO26 native is 640). (規劃書 §04)
    public var detectorImageSize: Int = 640
    /// Confidence threshold for a box to "qualify" — matches prescan `--conf`.
    public var detectorConf: Double = 0.45
    /// NMS IoU — matches prescan `--iou`.
    public var detectorIoU: Double = 0.7
    /// Minimum box height in **source pixels** to qualify — matches prescan `--min-height`.
    /// TODO(confirm): copy the production backend value (規劃書 §12 待你確認).
    public var minBoxHeight: Double = 40

    // ---- S0 prescan (ported from prescan_filter_valid_video.py) ----
    public var prescanStride: Int = 15
    public var prescanBufferSec: Double = 0.5
    public var prescanMaxGapSec: Double = 1.0
    /// Decode only sampled frames during prescan (`cap.grab()` equivalent).
    public var prescanUseGrab: Bool = true

    // ---- S2 detection cadence ----
    /// Run a fresh detection every N frames; extrapolate the bbox in between.
    /// 1 = detect every frame (baseline). Swept 1/3/6/auto in §08.
    public var detectorCadence: Int = 6
    /// Force a fresh detection if the tracker has coasted this many frames.
    public var trackerStalenessLimit: Int = 12
    /// Treat a fresh detection as the same runner when it overlaps the tracked box by at least this much.
    public var trackerMinIoU: Double = 0.05
    /// Fallback matching radius as a fraction of the source-frame diagonal when IoU is too low.
    public var trackerMaxCenterDistanceRatio: Double = 0.25

    // ---- concurrency / memory ----
    /// Max frames in flight across the S1–S5 pipeline. Memory ≈ maxInFlight × per-frame buffers.
    /// Old devices: 2 (規劃書 §04 / §12).
    public var maxInFlight: Int = 3

    // ---- thermal ----
    /// Under `.serious` thermal state, stretch `detectorCadence` and drop processing rate.
    public var adaptiveThermal: Bool = true

    // ---- debug / progress ----
    public var progressHandler: (@Sendable (PipelineProgress) -> Void)?

    // ---- postprocess ----
    /// Fast path for device-side benchmarking. Full DarkPose is accurate but expensive in
    /// pure Swift; the fast path uses argmax + local quarter-pixel refinement.
    public var fastHeatmapDecode: Bool = true

    // ---- HRNet model contract (fixed; do not change) ----
    /// Core ML input image size, width × height (規劃書 §02 模型契約).
    public let hrnetInputWidth = 288
    public let hrnetInputHeight = 384
    /// Heatmap size, width × height.
    public let heatmapWidth = 72
    public let heatmapHeight = 96
    /// DarkPose Gaussian modulation kernel (odd). MMPose config: 11.
    public let darkPoseKernel = 11

    public init() {}
}
