import Foundation

/// The runner's silhouette in the ROI the segmenter looked at: `mask` covers the source-frame
/// rectangle starting at (`left`, `top`).  Pixels outside it are not set.  The server's full-frame
/// mask (`mask[top:bottom, left:right] = roi_mask`) and this ROI form give the same sand mark, so
/// the phone never has to build a full-frame mask.
public struct RunnerMask: Sendable, Equatable {
    public var left: Int
    public var top: Int
    public var mask: BinaryMask

    public init(left: Int, top: Int, mask: BinaryMask) {
        self.left = left
        self.top = top
        self.mask = mask
    }

    /// A full-frame mask (the server's form).
    public init(fullFrame mask: BinaryMask) {
        self.init(left: 0, top: 0, mask: mask)
    }
}

/// Where the sand-mark search gets the runner's mask for a video frame (the Core ML segmenter on
/// the phone, a recording in tests).
public protocol RunnerMaskSource {
    /// The runner's mask in `frame`, given the tracked box (x1, y1, x2, y2 in source pixels), or
    /// nil when no runner is found.
    func runnerMask(frame: Int, box: SIMD4<Double>) throws -> RunnerMask?
}

/// A pixel rectangle `[left, right) x [top, bottom)` of the source frame.
public struct PixelROI: Sendable, Equatable {
    public var left: Int
    public var top: Int
    public var right: Int
    public var bottom: Int

    public init(left: Int, top: Int, right: Int, bottom: Int) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var width: Int { right - left }
    public var height: Int { bottom - top }
}

/// Pure parts of sand_mark.RunnerSegmenter the Core ML segmenter shares with the server.
public enum RunnerSegmentation {
    /// `RunnerSegmenter._roi`: the tracked box grown by `bboxMarginRatio` boxes on every side,
    /// floor/ceil, clamped to the frame; nil when empty.
    public static func roi(
        frameWidth: Int, frameHeight: Int, runnerBox box: SIMD4<Double>, rule: SandMarkRule = SandMarkRule()
    ) -> PixelROI? {
        guard (0..<4).allSatisfy({ box[$0].isFinite }) else { return nil }
        let marginX = (box[2] - box[0]) * rule.bboxMarginRatio
        let marginY = (box[3] - box[1]) * rule.bboxMarginRatio
        let left = Swift.max(0, Int((box[0] - marginX).rounded(.down)))
        let top = Swift.max(0, Int((box[1] - marginY).rounded(.down)))
        let right = Swift.min(frameWidth, Int((box[2] + marginX).rounded(.up)))
        let bottom = Swift.min(frameHeight, Int((box[3] + marginY).rounded(.up)))
        return right <= left || bottom <= top ? nil : PixelROI(left: left, top: top, right: right, bottom: bottom)
    }

    /// `_mask_from`'s runner choice: the index of the detected box (ROI coordinates, float32 as
    /// the model returns them) with the largest IoU with the tracked box; nil when there is none
    /// or the best IoU is below `minRunnerIou`.  First maximum wins (`argmax`).  The caller
    /// then thresholds that detection's mask at > 0.5 and crops it to the ROI size.
    public static func chooseRunner(
        detections: [SIMD4<Float>], runnerBox box: SIMD4<Double>, roi: PixelROI, rule: SandMarkRule = SandMarkRule()
    ) -> Int? {
        let local = SIMD4<Double>(
            box[0] - Double(roi.left), box[1] - Double(roi.top), box[2] - Double(roi.left), box[3] - Double(roi.top)
        )
        let overlaps = detections.map { iou(NPBox($0), NPBox(local)) }
        return pickRunner(overlaps: overlaps, rule: rule)
    }

    /// Same for float64 detection boxes.
    public static func chooseRunner(
        detections: [SIMD4<Double>], runnerBox box: SIMD4<Double>, roi: PixelROI, rule: SandMarkRule = SandMarkRule()
    ) -> Int? {
        let local = SIMD4<Double>(
            box[0] - Double(roi.left), box[1] - Double(roi.top), box[2] - Double(roi.left), box[3] - Double(roi.top)
        )
        return pickRunner(overlaps: detections.map { iou(NPBox($0), NPBox(local)) }, rule: rule)
    }

    /// `box_iou` of two float64 boxes.
    public static func boxIoU(_ a: SIMD4<Double>, _ b: SIMD4<Double>) -> Double {
        iou(NPBox(a), NPBox(b))
    }

    /// The ROI crop of a detected mask: `roi_mask[:bottom-top, :right-left]` placed at the ROI's
    /// corner (the model's mask may be a pixel larger or smaller than the ROI).
    public static func runnerMask(roiMask: BinaryMask, roi: PixelROI) -> RunnerMask {
        let width = Swift.min(roiMask.width, roi.width)
        let height = Swift.min(roiMask.height, roi.height)
        var out = BinaryMask(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width { out.data[y * width + x] = roiMask.data[y * roiMask.width + x] }
        }
        return RunnerMask(left: roi.left, top: roi.top, mask: out)
    }

    private static func pickRunner(overlaps: [Double], rule: SandMarkRule) -> Int? {
        guard var best = overlaps.first.map({ _ in 0 }) else { return nil }
        for i in overlaps.indices where overlaps[i] > overlaps[best] { best = i }
        return overlaps[best] < rule.minRunnerIou ? nil : best
    }
}

// MARK: - box_iou with numpy scalar types

/// A box whose coordinates are numpy scalars: float32 (the model's boxes) or float64.  The Python
/// `box_iou` does its arithmetic on those scalars, so the float32 subtractions and products must
/// round in float32 where numpy does.
struct NPBox {
    var x1, y1, x2, y2: NPScalar

    init(_ b: SIMD4<Float>) {
        (x1, y1, x2, y2) = (NPScalar(f32: b[0]), NPScalar(f32: b[1]), NPScalar(f32: b[2]), NPScalar(f32: b[3]))
    }

    init(_ b: SIMD4<Double>) {
        (x1, y1, x2, y2) = (NPScalar(b[0]), NPScalar(b[1]), NPScalar(b[2]), NPScalar(b[3]))
    }
}

struct NPScalar {
    var value: Double
    var isFloat32: Bool

    init(_ v: Double) { value = v; isFloat32 = false }
    init(f32 v: Float) { value = Double(v); isFloat32 = true }
    private init(_ v: Double, _ f32: Bool) { value = v; isFloat32 = f32 }

    static func - (a: NPScalar, b: NPScalar) -> NPScalar {
        a.isFloat32 && b.isFloat32
            ? NPScalar(f32: Float(a.value) - Float(b.value)) : NPScalar(a.value - b.value)
    }

    static func * (a: NPScalar, b: NPScalar) -> NPScalar {
        a.isFloat32 && b.isFloat32
            ? NPScalar(f32: Float(a.value) * Float(b.value)) : NPScalar(a.value * b.value)
    }

    static func + (a: NPScalar, b: NPScalar) -> NPScalar {
        a.isFloat32 && b.isFloat32
            ? NPScalar(f32: Float(a.value) + Float(b.value)) : NPScalar(a.value + b.value)
    }

    static func / (a: NPScalar, b: NPScalar) -> NPScalar {
        a.isFloat32 && b.isFloat32
            ? NPScalar(f32: Float(a.value) / Float(b.value)) : NPScalar(a.value / b.value)
    }

    /// Python `min(a, b)`: b only when b < a.
    static func pyMin(_ a: NPScalar, _ b: NPScalar) -> NPScalar { b.value < a.value ? b : a }
    /// Python `max(a, b)`: b only when b > a.
    static func pyMax(_ a: NPScalar, _ b: NPScalar) -> NPScalar { b.value > a.value ? b : a }
}

/// `sand_mark.box_iou`.
func iou(_ a: NPBox, _ b: NPBox) -> Double {
    let zero = NPScalar(0.0)  // Python float 0.0 (weak: leaves the other operand's dtype)
    let width = NPScalar.pyMax(zero, NPScalar.pyMin(a.x2, b.x2) - NPScalar.pyMax(a.x1, b.x1))
    let height = NPScalar.pyMax(zero, NPScalar.pyMin(a.y2, b.y2) - NPScalar.pyMax(a.y1, b.y1))
    let inter = width * height
    let union = (a.x2 - a.x1) * (a.y2 - a.y1) + (b.x2 - b.x1) * (b.y2 - b.y1) - inter
    return union.value > 0 ? (inter / union).value : 0.0
}
