import Foundation

/// Swift port of Server `compute_speed_from_bbox_map` for Local analysis.
/// The numerical order intentionally stays the same: monotonic distance,
/// flat-segment interpolation, bidirectional Butterworth low-pass, then a
/// constant-acceleration Kalman filter.
public struct ServerAlignedKinematicsProcessor: AnalysisKinematicsProcessing {
    public init() {}

    public func process(
        pose2D: Analysis2DResult,
        request: AnalysisRequest
    ) throws -> AnalysisKinematicsResult {
        let startedAt = Date()
        let rawSamples = try KinematicsTrajectoryBuilder.build(pose2D: pose2D, request: request)
        var frames: [AnalysisKinematicsFrame] = []
        var continuity = Continuity()
        var absoluteFrame = 0

        for camera in request.cameras.sorted(by: { $0.cameraIndex < $1.cameraIndex }) {
            let samples = rawSamples
                .filter { $0.cameraIndex == camera.cameraIndex }
                .sorted { $0.sourceFrame < $1.sourceFrame }
            guard !samples.isEmpty else { continue }

            let confidence = samples.map(\.measurementConfidence)
            let gapLengths = Self.interpolationGapLengths(confidence)
            let fps = camera.video.fps > 0 ? camera.video.fps : 60
            let pixelRaw = samples.map { $0.pixelDistanceM.map { $0 + continuity.pixelDistance } }
            let homographyRaw = samples.map {
                $0.homographyDistanceM.map { $0 + continuity.homographyDistance }
            }
            let pixel = Self.motionSeries(
                raw: pixelRaw,
                fps: fps,
                initialVelocity: continuity.pixelVelocity,
                initialAcceleration: continuity.pixelAcceleration,
                confidence: confidence,
                policy: request.kinematicsPolicy
            )
            let homography = Self.motionSeries(
                raw: homographyRaw,
                fps: fps,
                initialVelocity: continuity.homographyVelocity,
                initialAcceleration: continuity.homographyAcceleration,
                confidence: confidence,
                policy: request.kinematicsPolicy
            )

            if let pixel {
                continuity.pixelDistance = pixel.distance.last ?? continuity.pixelDistance
                continuity.pixelVelocity = pixel.velocity.last ?? continuity.pixelVelocity
                continuity.pixelAcceleration = pixel.acceleration.last
                    ?? continuity.pixelAcceleration
            }
            if let homography {
                continuity.homographyDistance = homography.distance.last
                    ?? continuity.homographyDistance
                continuity.homographyVelocity = homography.velocity.last
                    ?? continuity.homographyVelocity
                continuity.homographyAcceleration = homography.acceleration.last
                    ?? continuity.homographyAcceleration
            }

            // Server defaults to homography whenever that calibrated series is
            // available; otherwise it publishes the linear pixel projection.
            let activeMode: String
            let active: MotionSeries
            if request.kinematicsPolicy.speedMode != .pixel, let homography {
                activeMode = "homography"
                active = homography
            } else if request.kinematicsPolicy.speedMode != .homography, let pixel {
                activeMode = "pixel"
                active = pixel
            } else if let homography {
                activeMode = "homography"
                active = homography
            } else if let pixel {
                activeMode = "pixel"
                active = pixel
            } else {
                absoluteFrame += samples.count
                continue
            }

            for index in samples.indices {
                let sample = samples[index]
                frames.append(AnalysisKinematicsFrame(
                    cameraIndex: sample.cameraIndex,
                    cameraFrame: index,
                    sourceFrame: sample.sourceFrame,
                    absoluteFrame: absoluteFrame + index,
                    timestampSeconds: sample.timestampSeconds,
                    distanceM: active.distance[index],
                    rawDistanceM: active.raw[index],
                    smoothDistanceM: active.distance[index],
                    speedMPS: active.velocity[index],
                    accelerationMPS2: active.acceleration[index],
                    speedModeUsed: activeMode,
                    pixelDistanceM: pixel?.distance[index],
                    pixelSpeedMPS: pixel?.velocity[index],
                    pixelAccelerationMPS2: pixel?.acceleration[index],
                    homographyDistanceM: homography?.distance[index],
                    homographySpeedMPS: homography?.velocity[index],
                    homographyAccelerationMPS2: homography?.acceleration[index],
                    imagePointX: sample.centerX,
                    imagePointY: sample.bottomCenterY,
                    isInterpolated: sample.measurementConfidence < 1,
                    interpolationGapLength: gapLengths[index],
                    confidence: sample.measurementConfidence
                ))
            }
            absoluteFrame += samples.count
        }

        let warnings = frames.isEmpty
            ? ["No calibrated bbox distance series was available for Local kinematics."]
            : []
        return AnalysisKinematicsResult(
            frames: frames,
            durationSeconds: Date().timeIntervalSince(startedAt),
            warnings: warnings
        )
    }
}

private extension ServerAlignedKinematicsProcessor {
    struct Continuity {
        var pixelDistance = 0.0
        var pixelVelocity = 0.0
        var pixelAcceleration = 0.0
        var homographyDistance = 0.0
        var homographyVelocity = 0.0
        var homographyAcceleration = 0.0
    }

    struct MotionSeries {
        var raw: [Double?]
        var distance: [Double]
        var velocity: [Double]
        var acceleration: [Double]
    }

    static func motionSeries(
        raw: [Double?],
        fps: Double,
        initialVelocity: Double,
        initialAcceleration: Double,
        confidence: [Double],
        policy: AnalysisKinematicsPolicy
    ) -> MotionSeries? {
        guard raw.contains(where: { $0 != nil }) else { return nil }
        let filled = interpolateMissing(raw)
        var monotonic = filled
        for index in monotonic.indices.dropFirst() {
            monotonic[index] = max(monotonic[index], monotonic[index - 1])
        }
        monotonic = interpolateFlatSegments(
            monotonic,
            epsilon: policy.flatInterpolationEpsilonM
        )
        var distance = butterworthZeroPhase(
            monotonic,
            fps: fps,
            cutoff: policy.butterworthCutoffHz
        )
        for index in distance.indices.dropFirst() {
            distance[index] = max(distance[index], distance[index - 1])
        }
        if let first = monotonic.first {
            distance = distance.map { max($0, first) }
        }
        let state = kalmanVelocityAcceleration(
            distance: distance,
            fps: fps,
            initialVelocity: initialVelocity,
            initialAcceleration: initialAcceleration,
            confidence: confidence
        )
        return MotionSeries(
            raw: raw,
            distance: distance,
            velocity: state.velocity,
            acceleration: state.acceleration
        )
    }

    static func interpolateMissing(_ values: [Double?]) -> [Double] {
        let valid = values.indices.filter { values[$0] != nil }
        guard let first = valid.first, let last = valid.last else { return [] }
        var output = Array(repeating: values[first]!, count: values.count)
        for index in first...last where values[index] != nil {
            output[index] = values[index]!
        }
        for pairIndex in 1..<valid.count {
            let left = valid[pairIndex - 1]
            let right = valid[pairIndex]
            let start = values[left]!
            let end = values[right]!
            guard right > left + 1 else { continue }
            for index in (left + 1)..<right {
                let ratio = Double(index - left) / Double(right - left)
                output[index] = start + ratio * (end - start)
            }
        }
        if last + 1 < output.count {
            for index in (last + 1)..<output.count { output[index] = values[last]! }
        }
        return output
    }

    static func interpolateFlatSegments(_ input: [Double], epsilon: Double = 0.001) -> [Double] {
        guard input.count >= 3 else { return input }
        var output = input
        var index = 1
        while index < output.count {
            guard abs(output[index] - output[index - 1]) < epsilon else {
                index += 1
                continue
            }
            let flatStart = index - 1
            let flatValue = output[flatStart]
            var next = index
            while next < output.count, abs(output[next] - flatValue) < epsilon { next += 1 }
            let previous = flatStart - 1
            if previous >= 0, next < output.count, output[next] > output[previous] {
                let span = Double(next - previous)
                for position in flatStart..<next {
                    let ratio = Double(position - previous) / span
                    output[position] = output[previous]
                        + ratio * (output[next] - output[previous])
                }
            }
            index = max(next, index + 1)
        }
        return output
    }

    static func interpolationGapLengths(_ confidence: [Double]) -> [Int] {
        var result = Array(repeating: 0, count: confidence.count)
        var index = 0
        while index < confidence.count {
            guard confidence[index] < 1 else {
                index += 1
                continue
            }
            let start = index
            let value = confidence[index]
            while index < confidence.count, confidence[index] == value { index += 1 }
            let length = index - start
            for position in start..<index { result[position] = length }
        }
        return result
    }

    static func butterworthZeroPhase(
        _ input: [Double],
        fps: Double,
        cutoff: Double = 3.5
    ) -> [Double] {
        guard input.count >= 15, fps > 0, cutoff > 0, cutoff < fps / 2 else { return input }
        let k = tan(.pi * cutoff / fps)
        let norm = 1 / (1 + sqrt(2) * k + k * k)
        let b = [k * k * norm, 2 * k * k * norm, k * k * norm]
        let a = [1.0, 2 * (k * k - 1) * norm, (1 - sqrt(2) * k + k * k) * norm]
        let edge = 9
        guard input.count > edge else { return input }
        let left = (1...edge).reversed().map { 2 * input[0] - input[$0] }
        let right = (1...edge).map { 2 * input[input.count - 1] - input[input.count - 1 - $0] }
        let extended = left + input + right
        let forward = filter(extended, b: b, a: a)
        let backward = filter(Array(forward.reversed()), b: b, a: a).reversed()
        return Array(backward.dropFirst(edge).prefix(input.count))
    }

    /// Direct-form II transposed filter with SciPy-compatible steady-state zi.
    static func filter(_ input: [Double], b: [Double], a: [Double]) -> [Double] {
        guard let first = input.first else { return [] }
        var z0 = (1 - b[0]) * first
        var z1 = (b[2] - a[2]) * first
        var output: [Double] = []
        output.reserveCapacity(input.count)
        for value in input {
            let result = b[0] * value + z0
            let nextZ0 = b[1] * value - a[1] * result + z1
            z1 = b[2] * value - a[2] * result
            z0 = nextZ0
            output.append(result)
        }
        return output
    }

    static func kalmanVelocityAcceleration(
        distance: [Double],
        fps: Double,
        initialVelocity: Double,
        initialAcceleration: Double,
        confidence: [Double]
    ) -> (velocity: [Double], acceleration: [Double]) {
        guard distance.count >= 5, fps > 0 else {
            return (
                Array(repeating: 0, count: distance.count),
                Array(repeating: 0, count: distance.count)
            )
        }
        let dt = 1 / fps
        let transition = [
            [1.0, dt, 0.5 * dt * dt],
            [0.0, 1.0, dt],
            [0.0, 0.0, 1.0],
        ]
        let processNoise = [0.001, 0.01, 0.15]
        var state = [distance[0], initialVelocity, initialAcceleration]
        var covariance = [
            [1.0, 0.0, 0.0],
            [0.0, initialVelocity == 0 ? 1.0 : 0.1, 0.0],
            [0.0, 0.0, initialAcceleration == 0 ? 100.0 : 1.0],
        ]
        var velocities: [Double] = []
        var accelerations: [Double] = []
        velocities.reserveCapacity(distance.count)
        accelerations.reserveCapacity(distance.count)

        for index in distance.indices {
            state = multiply(transition, state)
            covariance = add(
                multiply(multiply(transition, covariance), transpose(transition)),
                diagonal(processNoise)
            )
            let measurementNoise = 0.15 / min(1, max(0.05, confidence[index]))
            let innovation = distance[index] - state[0]
            let innovationCovariance = covariance[0][0] + measurementNoise
            let gain = (0..<3).map { covariance[$0][0] / innovationCovariance }
            for row in 0..<3 { state[row] += gain[row] * innovation }
            let firstRow = covariance[0]
            for row in 0..<3 {
                for column in 0..<3 {
                    covariance[row][column] -= gain[row] * firstRow[column]
                }
            }
            velocities.append(max(0, state[1]))
            accelerations.append(state[2])
        }
        return (velocities, accelerations)
    }

    static func multiply(_ lhs: [[Double]], _ rhs: [Double]) -> [Double] {
        lhs.map { row in zip(row, rhs).map { $0.0 * $0.1 }.reduce(0, +) }
    }

    static func multiply(_ lhs: [[Double]], _ rhs: [[Double]]) -> [[Double]] {
        let rhsT = transpose(rhs)
        return lhs.map { row in
            rhsT.map { column in zip(row, column).map { $0.0 * $0.1 }.reduce(0, +) }
        }
    }

    static func transpose(_ matrix: [[Double]]) -> [[Double]] {
        guard let count = matrix.first?.count else { return [] }
        return (0..<count).map { column in matrix.map { $0[column] } }
    }

    static func diagonal(_ values: [Double]) -> [[Double]] {
        values.indices.map { row in values.indices.map { row == $0 ? values[row] : 0 } }
    }

    static func add(_ lhs: [[Double]], _ rhs: [[Double]]) -> [[Double]] {
        lhs.indices.map { row in lhs[row].indices.map { lhs[row][$0] + rhs[row][$0] } }
    }
}
