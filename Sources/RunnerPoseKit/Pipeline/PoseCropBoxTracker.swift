import CoreGraphics
import Foundation

/// Builds a temporally stable HRNet crop without changing the detector box that
/// is persisted in `RunnerPose` and consumed by downstream kinematics.
///
/// A fresh detector box can become too tight for a single motion-blurred frame.
/// The centre follows the current detection with an EMA while width and height
/// grow immediately and shrink gradually. This avoids both clipped limbs and
/// the motion-trail whitespace produced by a full two-frame union.
struct PoseCropBoxTracker {
    private var previous: (frame: Int, raw: BBox, stable: BBox)?

    mutating func cropBox(
        for current: BBox,
        frame: Int,
        frameSize: CGSize,
        centerAlpha: Double,
        shrinkRetention: Double
    ) -> BBox {
        guard current.width > 0, current.height > 0 else {
            reset()
            return current
        }
        guard let previous,
              frame == previous.frame + 1,
              isPlausibleContinuation(from: previous.raw, to: current)
        else {
            self.previous = (frame, current, current)
            return current
        }

        let alpha = min(1, max(0, centerAlpha))
        let retention = min(1, max(0, shrinkRetention))
        let centerX = alpha * current.centerX + (1 - alpha) * previous.stable.centerX
        let centerY = alpha * current.centerY + (1 - alpha) * previous.stable.centerY
        let width = max(current.width, previous.stable.width * retention)
        let height = max(current.height, previous.stable.height * retention)

        let stable = BBox(
            x1: max(0, centerX - width * 0.5),
            y1: max(0, centerY - height * 0.5),
            x2: min(Double(frameSize.width), centerX + width * 0.5),
            y2: min(Double(frameSize.height), centerY + height * 0.5)
        )
        self.previous = (frame, current, stable)
        return stable
    }

    mutating func reset() {
        previous = nil
    }

    private func isPlausibleContinuation(from previous: BBox, to current: BBox) -> Bool {
        guard previous.width > 0, previous.height > 0 else { return false }
        let referenceLength = max(
            max(previous.width, previous.height),
            max(current.width, current.height)
        )
        // Adjacent boxes may move during a sprint, but a shift larger than most
        // of the runner's box is more likely a track switch than body motion.
        return previous.centerDistance(to: current) <= referenceLength * 0.75
    }
}
