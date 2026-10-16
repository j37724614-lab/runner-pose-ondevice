import CoreGraphics
import Foundation

/// Builds a temporally stable HRNet crop without changing the detector box that
/// is persisted in `RunnerPose` and consumed by downstream kinematics.
///
/// A fresh detector box can become too tight for a single motion-blurred frame.
/// For adjacent frames of the same track, use the smallest rectangle containing
/// both boxes. `Geometry.boxToCenterScale` applies the existing 1.25 safety scale
/// after this union is formed.
struct PoseCropBoxTracker {
    private var previous: (frame: Int, box: BBox)?

    mutating func cropBox(
        for current: BBox,
        frame: Int,
        frameSize: CGSize
    ) -> BBox {
        defer { previous = (frame, current) }

        guard current.width > 0, current.height > 0,
              let previous,
              frame == previous.frame + 1,
              isPlausibleContinuation(from: previous.box, to: current)
        else {
            return current
        }

        return BBox(
            x1: max(0, min(previous.box.x1, current.x1)),
            y1: max(0, min(previous.box.y1, current.y1)),
            x2: min(Double(frameSize.width), max(previous.box.x2, current.x2)),
            y2: min(Double(frameSize.height), max(previous.box.y2, current.y2))
        )
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
