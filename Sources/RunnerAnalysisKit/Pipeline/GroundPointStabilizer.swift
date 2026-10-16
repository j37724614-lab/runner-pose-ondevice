import Foundation

/// Removes isolated detector-box jumps before the bottom-centre point is
/// converted through the camera calibration.  This is deliberately separate
/// from the HRNet crop stabilizer: pose crops may lag and grow, while speed
/// needs the runner's original image-space trajectory.
struct GroundPointMeasurement: Sendable, Equatable {
    var x: Double
    var centerY: Double
    var bottomY: Double
    var confidence: Double
    var repaired: Bool
}

enum GroundPointStabilizer {
    private struct Sample {
        var x: Double
        var centerY: Double
        var bottomY: Double
        var width: Double
        var height: Double
        var confidence: Double
        var outlier = false
    }

    static func stabilize(frames: [Pose2DFrame]) -> [GroundPointMeasurement?] {
        guard !frames.isEmpty else { return [] }
        var samples: [Sample?] = frames.map { frame in
            guard let box = frame.bbox, box.x2 > box.x1, box.y2 > box.y1 else { return nil }
            return Sample(
                x: (box.x1 + box.x2) * 0.5,
                centerY: (box.y1 + box.y2) * 0.5,
                bottomY: box.y2,
                width: box.x2 - box.x1,
                height: box.y2 - box.y1,
                confidence: frame.bboxExtrapolated ? 0.7 : 1.0
            )
        }

        // A five-frame Hampel-style gate catches a one-frame tight or shifted
        // YOLO box without suppressing the runner's normal monotonic motion.
        for index in samples.indices {
            guard var sample = samples[index] else { continue }
            guard index >= 2, index + 2 < samples.count else { continue }
            let lower = max(0, index - 2)
            let upper = min(samples.count - 1, index + 2)
            let neighbourhood = (lower...upper).compactMap { samples[$0] }
            guard neighbourhood.count >= 3 else { continue }
            let medianX = median(neighbourhood.map(\.x))
            let medianCenterY = median(neighbourhood.map(\.centerY))
            let medianBottomY = median(neighbourhood.map(\.bottomY))
            let medianWidth = max(1, median(neighbourhood.map(\.width)))
            let medianHeight = max(1, median(neighbourhood.map(\.height)))
            let centerResidual = hypot(sample.x - medianX, sample.centerY - medianCenterY)
            let bottomResidual = hypot(sample.x - medianX, sample.bottomY - medianBottomY)
            let pointResidual = max(centerResidual, bottomResidual)
            let pointLimit = max(8, medianHeight * 0.12)
            let widthRatio = sample.width / medianWidth
            let heightRatio = sample.height / medianHeight
            let sizeJump = widthRatio < 0.70 || widthRatio > 1.30
                || heightRatio < 0.70 || heightRatio > 1.30
            let isolatedPointJump = pointResidual > pointLimit

            // Size alone is not enough: real limb extension changes a box.
            // Repair it only when the ground point also leaves its local path.
            if isolatedPointJump || (sizeJump && pointResidual > pointLimit * 0.55) {
                sample.outlier = true
                sample.confidence = min(sample.confidence, 0.25)
                samples[index] = sample
            }
        }

        var result: [GroundPointMeasurement?] = samples.map { sample in
            guard let sample, !sample.outlier else { return nil }
            return GroundPointMeasurement(
                x: sample.x,
                centerY: sample.centerY,
                bottomY: sample.bottomY,
                confidence: sample.confidence,
                repaired: false
            )
        }
        interpolateMissing(&result)

        // A three-frame median removes residual one-pixel box-edge chatter.
        // On a monotonic sprint path the centre sample is unchanged.
        let repaired = result
        for index in result.indices {
            guard var value = result[index] else { continue }
            let lower = max(0, index - 1)
            let upper = min(result.count - 1, index + 1)
            let window = (lower...upper).compactMap { repaired[$0] }
            if window.count == 3 {
                value.x = median(window.map(\.x))
                value.centerY = median(window.map(\.centerY))
                value.bottomY = median(window.map(\.bottomY))
                result[index] = value
            }
        }
        return result
    }

    private static func interpolateMissing(_ values: inout [GroundPointMeasurement?]) {
        let valid = values.indices.filter { values[$0] != nil }
        guard let first = valid.first, let last = valid.last else { return }
        if first > 0 {
            for index in 0..<first {
                var value = values[first]!
                value.confidence = min(value.confidence, 0.2)
                value.repaired = true
                values[index] = value
            }
        }
        for pair in 1..<valid.count {
            let left = valid[pair - 1]
            let right = valid[pair]
            guard right > left + 1 else { continue }
            let start = values[left]!
            let end = values[right]!
            for index in (left + 1)..<right {
                let ratio = Double(index - left) / Double(right - left)
                values[index] = GroundPointMeasurement(
                    x: start.x + (end.x - start.x) * ratio,
                    centerY: start.centerY + (end.centerY - start.centerY) * ratio,
                    bottomY: start.bottomY + (end.bottomY - start.bottomY) * ratio,
                    confidence: 0.25,
                    repaired: true
                )
            }
        }
        if last + 1 < values.count {
            for index in (last + 1)..<values.count {
                var value = values[last]!
                value.confidence = min(value.confidence, 0.2)
                value.repaired = true
                values[index] = value
            }
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) * 0.5
        }
        return sorted[middle]
    }
}
