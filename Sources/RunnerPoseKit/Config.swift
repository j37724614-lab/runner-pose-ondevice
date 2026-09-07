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
    public var detectorConf: Double = 0.25
    /// NMS IoU — matches prescan `--iou`.
    public var detectorIoU: Double = 0.7
    /// Minimum box height in **source pixels** to qualify — matches prescan `--min-height`.
    /// TODO(confirm): copy the production backend value (規劃書 §12 待你確認).
    public var minBoxHeight: Double = 40

    // ---- S0 prescan (ported from prescan_filter_valid_video.py) ----
    public var prescanStride: Int = 8
    public var prescanBufferSec: Double = 1.0
    public var prescanMaxGapSec: Double = 1.0
    /// Decode only sampled frames during prescan (`cap.grab()` equivalent).
    public var prescanUseGrab: Bool = true

    // ---- S2 detection cadence ----
    /// Run a fresh detection every N frames; extrapolate the bbox in between.
    /// 1 = detect every frame (baseline). Swept 1/3/6/auto in §08.
    public var detectorCadence: Int = 6
    /// Force a fresh detection if the tracker has coasted this many frames.
    public var trackerStalenessLimit: Int = 12

    // ---- concurrency / memory ----
    /// Max frames in flight across the S1–S5 pipeline. Memory ≈ maxInFlight × per-frame buffers.
    /// Old devices: 2 (規劃書 §04 / §12).
    public var maxInFlight: Int = 3

    // ---- thermal ----
    /// Under `.serious` thermal state, stretch `detectorCadence` and drop processing rate.
    public var adaptiveThermal: Bool = true

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
