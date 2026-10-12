import Foundation

/// Step 18's first numerical seam. It deliberately emits raw measurements,
/// not publishable speed metrics: filtering, Kalman state and cross-camera
/// continuity are separate stages with separate parity fixtures.
struct RawKinematicsSample: Sendable, Equatable {
    var cameraIndex: Int
    var sourceFrame: Int
    var timestampSeconds: Double
    var centerX: Double
    var centerY: Double
    var bottomCenterY: Double
    var pixelDistanceM: Double?
    var homographyDistanceM: Double?
    var measurementConfidence: Double
}

enum KinematicsTrajectoryBuilder {
    static func build(
        pose2D: Analysis2DResult,
        request: AnalysisRequest
    ) throws -> [RawKinematicsSample] {
        var result: [RawKinematicsSample] = []
        for camera in request.cameras.sorted(by: { $0.cameraIndex < $1.cameraIndex }) {
            let frames = pose2D.frames
                .filter { $0.cameraIndex == camera.cameraIndex }
                .sorted { $0.sourceFrame < $1.sourceFrame }
            guard !frames.isEmpty else { continue }
            let geometry = try CameraGeometry(
                calibration: camera.calibration,
                laneWidthM: request.kinematicsPolicy.laneWidthM
            )
            let confidences = interpolationConfidences(frames.map(\.bboxExtrapolated))
            for (index, frame) in frames.enumerated() {
                guard let bbox = frame.bbox else { continue }
                let centerX = (bbox.x1 + bbox.x2) / 2
                let centerY = (bbox.y1 + bbox.y2) / 2
                result.append(RawKinematicsSample(
                    cameraIndex: camera.cameraIndex,
                    sourceFrame: frame.sourceFrame,
                    timestampSeconds: frame.timestampSeconds,
                    centerX: centerX,
                    centerY: centerY,
                    bottomCenterY: bbox.y2,
                    pixelDistanceM: geometry.pixelDistance(x: centerX, y: centerY),
                    homographyDistanceM: geometry.homographyDistance(
                        x: centerX,
                        bottomY: bbox.y2
                    ),
                    measurementConfidence: confidences[index]
                ))
            }
        }
        return result
    }

    static func interpolationConfidences(_ extrapolated: [Bool]) -> [Double] {
        var result = Array(repeating: 1.0, count: extrapolated.count)
        var index = 0
        while index < extrapolated.count {
            guard extrapolated[index] else {
                index += 1
                continue
            }
            let start = index
            while index < extrapolated.count && extrapolated[index] { index += 1 }
            let length = index - start
            let confidence = length <= 3 ? 0.7 : (length <= 8 ? 0.4 : 0.2)
            for position in start..<index { result[position] = confidence }
        }
        return result
    }
}

private struct CameraGeometry {
    var startMid: AnalysisPoint?
    var direction: AnalysisPoint?
    var metersPerPixel: Double?
    var homography: Homography?
    var homographyStartX: Double?

    init(calibration: AnalysisCalibration?, laneWidthM: Double) throws {
        guard let calibration else { return }
        var pixelSpan: Double?
        if let start = calibration.startLine, let end = calibration.endLine,
           start.count == 2, end.count == 2 {
            let startMid = Self.midpoint(start[0], start[1])
            let endMid = Self.midpoint(end[0], end[1])
            let dx = endMid.x - startMid.x
            let dy = endMid.y - startMid.y
            let span = hypot(dx, dy)
            if span > 0 {
                self.startMid = startMid
                direction = AnalysisPoint(x: dx / span, y: dy / span)
                pixelSpan = span
            }
        }
        if let image = calibration.homographyImagePoints,
           let world = calibration.homographyWorldPointsM {
            homography = try Homography(imagePoints: image, worldPoints: world)
        } else if let start = calibration.startLine, let end = calibration.endLine,
                  start.count == 2, end.count == 2,
                  let distance = calibration.distanceM {
            let orderedStart = Self.orderedByY(start)
            let orderedEnd = Self.orderedByY(end)
            homography = try? Homography(
                imagePoints: [orderedStart.0, orderedStart.1, orderedEnd.0, orderedEnd.1],
                worldPoints: [
                    AnalysisPoint(x: 0, y: 0), AnalysisPoint(x: 0, y: laneWidthM),
                    AnalysisPoint(x: distance, y: 0),
                    AnalysisPoint(x: distance, y: laneWidthM),
                ]
            )
        }
        if let homography,
           let start = calibration.startLine, start.count == 2,
           let first = homography.transform(start[0]),
           let second = homography.transform(start[1]) {
            homographyStartX = (first.x + second.x) / 2
        } else if homography != nil {
            homographyStartX = 0
        } else if let distance = calibration.distanceM, let pixelSpan, pixelSpan > 0 {
            // Matches Server only when homography construction is unavailable.
            metersPerPixel = distance / pixelSpan
        }
    }

    func pixelDistance(x: Double, y: Double) -> Double? {
        guard let startMid, let direction, let metersPerPixel else { return nil }
        let projection = (x - startMid.x) * direction.x + (y - startMid.y) * direction.y
        return max(0, projection * metersPerPixel)
    }

    func homographyDistance(x: Double, bottomY: Double) -> Double? {
        guard let homography else { return nil }
        var point = AnalysisPoint(x: x, y: bottomY)
        if let startMid, let direction {
            let projection = (point.x - startMid.x) * direction.x
                + (point.y - startMid.y) * direction.y
            point = AnalysisPoint(
                x: startMid.x + direction.x * projection,
                y: startMid.y + direction.y * projection
            )
        }
        guard let world = homography.transform(point) else { return nil }
        return max(0, world.x - (homographyStartX ?? 0))
    }

    private static func midpoint(_ lhs: AnalysisPoint, _ rhs: AnalysisPoint) -> AnalysisPoint {
        AnalysisPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
    }

    private static func orderedByY(_ line: [AnalysisPoint]) -> (AnalysisPoint, AnalysisPoint) {
        line[0].y <= line[1].y ? (line[0], line[1]) : (line[1], line[0])
    }
}

private struct Homography {
    /// Row-major 3x3 matrix with the final scale fixed to one.
    var values: [Double]

    init(imagePoints: [AnalysisPoint], worldPoints: [AnalysisPoint]) throws {
        guard imagePoints.count == worldPoints.count, imagePoints.count >= 4 else {
            throw RunnerAnalysisError.invalidRequest(
                "Homography needs at least four matching image/world points."
            )
        }
        var rows: [[Double]] = []
        var targets: [Double] = []
        for (source, destination) in zip(imagePoints, worldPoints) {
            rows.append([
                source.x, source.y, 1, 0, 0, 0,
                -destination.x * source.x, -destination.x * source.y,
            ])
            targets.append(destination.x)
            rows.append([
                0, 0, 0, source.x, source.y, 1,
                -destination.y * source.x, -destination.y * source.y,
            ])
            targets.append(destination.y)
        }
        let count = 8
        var normal = Array(repeating: Array(repeating: 0.0, count: count), count: count)
        var right = Array(repeating: 0.0, count: count)
        for row in rows.indices {
            for left in 0..<count {
                right[left] += rows[row][left] * targets[row]
                for column in 0..<count {
                    normal[left][column] += rows[row][left] * rows[row][column]
                }
            }
        }
        guard let solution = Self.solve(normal, right) else {
            throw RunnerAnalysisError.invalidRequest(
                "Homography points are singular or nearly collinear."
            )
        }
        values = solution + [1]
    }

    func transform(_ point: AnalysisPoint) -> AnalysisPoint? {
        let denominator = values[6] * point.x + values[7] * point.y + values[8]
        guard abs(denominator) > 1e-12 else { return nil }
        return AnalysisPoint(
            x: (values[0] * point.x + values[1] * point.y + values[2]) / denominator,
            y: (values[3] * point.x + values[4] * point.y + values[5]) / denominator
        )
    }

    private static func solve(_ matrix: [[Double]], _ target: [Double]) -> [Double]? {
        let count = target.count
        var rows = matrix.enumerated().map { $0.element + [target[$0.offset]] }
        for column in 0..<count {
            guard let pivot = (column..<count).max(by: {
                abs(rows[$0][column]) < abs(rows[$1][column])
            }), abs(rows[pivot][column]) > 1e-10 else { return nil }
            rows.swapAt(column, pivot)
            let scale = rows[column][column]
            for item in column...count { rows[column][item] /= scale }
            for row in 0..<count where row != column {
                let factor = rows[row][column]
                for item in column...count {
                    rows[row][item] -= factor * rows[column][item]
                }
            }
        }
        return rows.map { $0[count] }
    }
}
