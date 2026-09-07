import Foundation

/// Constant-velocity bbox extrapolation for the frames between detections (S2).
///
/// The runner moves smoothly and roughly linearly across a 5-frame gap, so linear
/// extrapolation of the box centre + size is enough for the baseline. If the §07
/// cadence sweep shows drift on curves / acceleration, swap this for a Kalman filter
/// (規劃書 §07 / §12) — the `Config.detectorCadence` knob and this type are the seam.
struct BBoxTracker {
    private var last: (frame: Int, box: BBox)?
    private var prev: (frame: Int, box: BBox)?
    /// Frames since the last *fresh detection*.
    private(set) var coastedFrames = 0

    /// Feed a fresh detection result.
    mutating func observe(box: BBox, frame: Int) {
        prev = last
        last = (frame, box)
        coastedFrames = 0
    }

    /// Predicted box for a frame with no detection. Returns the last box unchanged
    /// if there is no velocity estimate yet.
    mutating func predict(frame: Int) -> BBox? {
        guard let last else { return nil }
        coastedFrames = frame - last.frame
        guard let prev, last.frame != prev.frame else { return last.box }

        let dt = Double(last.frame - prev.frame)
        let steps = Double(frame - last.frame)
        func lerp(_ a: Double, _ b: Double) -> Double { b + (b - a) / dt * steps }

        return BBox(
            x1: lerp(prev.box.x1, last.box.x1),
            y1: lerp(prev.box.y1, last.box.y1),
            x2: lerp(prev.box.x2, last.box.x2),
            y2: lerp(prev.box.y2, last.box.y2)
        )
    }

    var lastBox: BBox? { last?.box }
}
