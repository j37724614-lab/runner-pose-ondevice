import CoreGraphics
import CoreMedia

/// The 23 wholebody joints, in the exact order the HRNet Core ML model emits them.
///
/// Source of truth: `HRNetRunnerWholeBody23.conversion.json` `joint_names`
/// (runner-analysis-pipeline). Downstream stages (leg-identity, MotionAGFormer, gait)
/// depend on this order — do not reorder. (規劃書 §02 輸出 schema)
public enum JointName: Int, CaseIterable, Sendable {
    case nose = 0
    case leftEye, rightEye, leftEar, rightEar
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
    case leftBigToe, leftSmallToe, leftHeel
    case rightBigToe, rightSmallToe, rightHeel

    public static let count = 23

    public enum Side: Sendable, Equatable {
        case left, right, center
    }

    public var side: Side {
        switch self {
        case .leftEye, .leftEar, .leftShoulder, .leftElbow, .leftWrist,
             .leftHip, .leftKnee, .leftAnkle, .leftBigToe, .leftSmallToe, .leftHeel:
            return .left
        case .rightEye, .rightEar, .rightShoulder, .rightElbow, .rightWrist,
             .rightHip, .rightKnee, .rightAnkle, .rightBigToe, .rightSmallToe, .rightHeel:
            return .right
        case .nose:
            return .center
        }
    }
}

/// One detected joint, in **original video-frame pixel coordinates**.
public struct Joint: Sendable, Equatable {
    public var name: JointName
    public var x: Double
    public var y: Double
    /// Heatmap peak value (pre-DarkPose), roughly a confidence. Not normalised.
    public var score: Double

    public init(name: JointName, x: Double, y: Double, score: Double) {
        self.name = name
        self.x = x
        self.y = y
        self.score = score
    }
}

/// Axis-aligned person box in original video-frame pixels.
public struct BBox: Sendable, Equatable {
    public var x1: Double
    public var y1: Double
    public var x2: Double
    public var y2: Double

    public init(x1: Double, y1: Double, x2: Double, y2: Double) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }

    public var width: Double { x2 - x1 }
    public var height: Double { y2 - y1 }
    public var centerX: Double { x1 + width * 0.5 }
    public var centerY: Double { y1 + height * 0.5 }
    public var bottomCenter: RunnerRegionPoint { RunnerRegionPoint(x: centerX, y: y2) }
    public var cgRect: CGRect { CGRect(x: x1, y: y1, width: width, height: height) }

    /// Intersection-over-union with another box. Used by the tracker and by
    /// `PrescanParityTests` / detector-scale comparison (規劃書 §07).
    public func iou(_ other: BBox) -> Double {
        let ix1 = max(x1, other.x1), iy1 = max(y1, other.y1)
        let ix2 = min(x2, other.x2), iy2 = min(y2, other.y2)
        let iw = max(0, ix2 - ix1), ih = max(0, iy2 - iy1)
        let inter = iw * ih
        let union = width * height + other.width * other.height - inter
        return union > 0 ? inter / union : 0
    }

    public func centerDistance(to other: BBox) -> Double {
        hypot(centerX - other.centerX, centerY - other.centerY)
    }
}

public struct RunnerRegionPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Track segment selected by the calibration anchors. A runner qualifies while
/// the bottom centre of the person box projects between the Server-compatible
/// start and end margins.
public struct RunnerRegionOfInterest: Sendable, Equatable {
    public var points: [RunnerRegionPoint]
    public var preRollPixels: Double
    public var endRollPixels: Double

    public init(
        points: [RunnerRegionPoint],
        preRollPixels: Double = 200,
        endRollPixels: Double = 120
    ) {
        self.points = points
        self.preRollPixels = preRollPixels
        self.endRollPixels = endRollPixels
    }

    public var startMidpoint: RunnerRegionPoint? {
        guard points.count >= 4 else { return nil }
        return Self.midpoint(points[0], points[3])
    }

    public var endMidpoint: RunnerRegionPoint? {
        guard points.count >= 4 else { return nil }
        return Self.midpoint(points[1], points[2])
    }

    public var pixelSpan: Double? {
        guard let startMidpoint, let endMidpoint else { return nil }
        let span = hypot(endMidpoint.x - startMidpoint.x, endMidpoint.y - startMidpoint.y)
        return span > 0 ? span : nil
    }

    /// Projection along the Server track direction. Zero is the start line;
    /// `pixelSpan` is the end line.
    public func projection(_ point: RunnerRegionPoint) -> Double? {
        guard let startMidpoint, let endMidpoint, let pixelSpan else { return nil }
        let directionX = (endMidpoint.x - startMidpoint.x) / pixelSpan
        let directionY = (endMidpoint.y - startMidpoint.y) / pixelSpan
        return (point.x - startMidpoint.x) * directionX
            + (point.y - startMidpoint.y) * directionY
    }

    public func contains(_ box: BBox) -> Bool {
        guard let projected = projection(box.bottomCenter), let pixelSpan else { return false }
        return -preRollPixels <= projected && projected <= pixelSpan + endRollPixels
    }

    public func projection(_ box: BBox) -> Double? {
        projection(box.bottomCenter)
    }

    private static func midpoint(
        _ first: RunnerRegionPoint,
        _ second: RunnerRegionPoint
    ) -> RunnerRegionPoint {
        RunnerRegionPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }
}

/// Result for one processed frame.
public struct RunnerPose: Sendable {
    public var frameIndex: Int
    public var timestamp: CMTime
    /// The box actually used to crop this frame (fresh detection or tracker extrapolation).
    public var bbox: BBox?
    /// 23 joints in `JointName` order. Empty when `valid == false`.
    public var joints: [Joint]
    /// Passed the S2 validity gate (a qualifying runner box exists this frame).
    public var valid: Bool
    /// True when `bbox` came from the tracker, not a fresh detection (規劃書 §07 精度風險).
    public var bboxExtrapolated: Bool

    public init(
        frameIndex: Int,
        timestamp: CMTime,
        bbox: BBox?,
        joints: [Joint],
        valid: Bool,
        bboxExtrapolated: Bool
    ) {
        self.frameIndex = frameIndex
        self.timestamp = timestamp
        self.bbox = bbox
        self.joints = joints
        self.valid = valid
        self.bboxExtrapolated = bboxExtrapolated
    }
}
