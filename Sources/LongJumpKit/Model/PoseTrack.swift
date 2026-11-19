import Foundation

/// detection.PoseTrack: per-frame signals of the selected runner; index i <-> video frame
/// `frames[i]`.  Missing values are NaN, as in the numpy arrays.
public struct PoseTrack: Sendable, Equatable {
    /// Joints the foot speed uses (detection.FOOT_JOINTS_FOR_SPEED).
    public static let footJointsForSpeed = ["big_toe", "small_toe"]

    public var frames: [Int]
    public var timestamps: [Double]
    /// [frame][joint] image points.
    public var jointsXY: [[SIMD2<Double>]]
    /// [frame][joint] scores.
    public var jointScores: [[Double]]
    public var jointIndex: [String: Int]
    /// [frame] x1, y1, x2, y2 of the tracked runner box (NaN when the frame has none).
    public var boxes: [SIMD4<Double>]

    public init(
        frames: [Int],
        timestamps: [Double],
        jointsXY: [[SIMD2<Double>]],
        jointScores: [[Double]],
        jointIndex: [String: Int],
        boxes: [SIMD4<Double>]
    ) {
        precondition(
            [timestamps.count, jointsXY.count, jointScores.count, boxes.count].allSatisfy { $0 == frames.count }
        )
        self.frames = frames
        self.timestamps = timestamps
        self.jointsXY = jointsXY
        self.jointScores = jointScores
        self.jointIndex = jointIndex
        self.boxes = boxes
    }

    public var count: Int { frames.count }

    /// Frames per second from the timestamps.
    public var fps: Double {
        Double(timestamps.count - 1) / (timestamps[timestamps.count - 1] - timestamps[0])
    }

    /// Box bottom y2, NaN filled.
    public var bottomY: [Double] { NP.fillNaN(boxes.map { $0[3] }) }

    /// Box height y2 - y1, NaN filled.
    public var boxHeights: [Double] { NP.fillNaN(boxes.map { $0[3] - $0[1] }) }

    /// Image points of one joint over the track (all NaN when the track has no such joint; the
    /// Python raises KeyError there, which the pipeline's 23-joint layout never triggers).
    public func jointXY(_ name: String) -> [SIMD2<Double>] {
        guard let column = jointIndex[name] else {
            return [SIMD2<Double>](repeating: SIMD2(.nan, .nan), count: count)
        }
        return jointsXY.map { $0[column] }
    }

    /// Score of one joint at one index (0 when the track has no such joint).
    public func jointScore(_ name: String, at index: Int) -> Double {
        guard let column = jointIndex[name] else { return 0 }
        return jointScores[index][column]
    }

    /// Hip speed along the run direction (px/frame), for runs toward either side of the frame.
    public func hipSpeedTowardPit() -> [Double] {
        let left = jointXY("left_hip")
        let right = jointXY("right_hip")
        let hipX = zip(left, right).map { ($0.x + $1.x) / 2 }
        let velocity = NP.gradient(hipX)
        return NP.nanMedian(velocity) > 0 ? velocity : velocity.map { -$0 }
    }

    /// |vx| of the slower foot, so a left/right keypoint swap cannot affect it.
    public func slowestFootSpeed() -> [Double] {
        let speeds = Side.allCases.map { side -> [Double] in
            let a = jointXY("\(side.rawValue)_\(Self.footJointsForSpeed[0])")
            let b = jointXY("\(side.rawValue)_\(Self.footJointsForSpeed[1])")
            let footX = zip(a, b).map { ($0.x + $1.x) / 2 }
            return NP.gradient(footX).map { Swift.abs($0) }
        }
        return NP.minimum(speeds[0], speeds[1])
    }

    /// 2D speed of the big/small-toe centre of one foot, in bbox heights per second, median
    /// smoothed (`foot_speed_2d_per_s` / `toe_center_speed_2d_per_s`).
    public func toeCenterSpeed2DPerS(_ side: Side, smoothing: Int = 3) -> [Double] {
        let a = jointXY("\(side.rawValue)_\(Self.footJointsForSpeed[0])")
        let b = jointXY("\(side.rawValue)_\(Self.footJointsForSpeed[1])")
        let xs = NP.fillNaN(zip(a, b).map { ($0.x + $1.x) / 2 })
        let ys = NP.fillNaN(zip(a, b).map { ($0.y + $1.y) / 2 })
        let dx = NP.gradient(xs)
        let dy = NP.gradient(ys)
        let heights = boxHeights
        let rate = fps
        let normalized = (0..<count).map { i in (dx[i] * dx[i] + dy[i] * dy[i]).squareRoot() * rate / heights[i] }
        return NP.medianFilterNearest(normalized, size: smoothing)
    }

    /// Video frame -> track index.
    public func indexByFrame() -> [Int: Int] {
        var map: [Int: Int] = [:]
        for (index, frame) in frames.enumerated() { map[frame] = index }
        return map
    }

    /// The first `endIndex` frames.
    public func until(_ endIndex: Int) -> PoseTrack {
        let end = Swift.min(Swift.max(endIndex, 0), count)
        return PoseTrack(
            frames: Array(frames[..<end]),
            timestamps: Array(timestamps[..<end]),
            jointsXY: Array(jointsXY[..<end]),
            jointScores: Array(jointScores[..<end]),
            jointIndex: jointIndex,
            boxes: Array(boxes[..<end])
        )
    }

    /// Side of the frame the athlete runs toward (where the pit is), from the hip motion
    /// (detection.pit_side_of).
    public func pitSide() -> Side {
        let left = jointXY("left_hip")
        let right = jointXY("right_hip")
        let hipX = NP.fillNaN(zip(left, right).map { ($0.x + $1.x) / 2 })
        return NP.nanMedian(NP.gradient(hipX)) < 0 ? .left : .right
    }

    /// Take-off foot: the foot whose toe centre moves slower between board contact (TD) and
    /// toe-off (TO) -- the foot on the board hardly moves (detection.takeoff_foot).  TD..TO when
    /// both exist, the one frame otherwise; nil without either.  A foot without any toe speed
    /// (NaN) loses; ties go to the left foot.
    public func takeoffFoot(_ events: JumpEvents) -> Side? {
        let byFrame = indexByFrame()
        let indices = [events.boardContact, events.toeOff].compactMap { $0 }.compactMap { byFrame[$0] }
        guard let low = indices.min(), let high = indices.max() else { return nil }
        var best: (side: Side, speed: Double)?
        for side in Side.allCases {
            let speed = NP.nanMean(Array(toeCenterSpeed2DPerS(side)[low...high]))
            let key = speed.isFinite ? speed : .infinity
            if best == nil || key < best!.speed { best = (side, key) }
        }
        return best?.side
    }
}

// MARK: - Loading the pipeline's pose/keypoints_2d.json

public enum PoseTrackError: Error, Equatable, CustomStringConvertible {
    case noValidFrames
    case noFramesForCamera(Int)

    public var description: String {
        switch self {
        case .noValidFrames: return "no valid pose frames"
        case .noFramesForCamera(let camera): return "camera \(camera) has no valid pose frames"
        }
    }
}

extension PoseTrack {
    /// Valid frames of one camera of a `pose/keypoints_2d.json` and their tracked runner box
    /// (detection.load_pose_track_from_keypoints).  `cameraIndex` nil = the last camera (the one
    /// filming board and pit).  Frames without a box get NaN boxes.
    public static func load(keypointsJSON data: Data, cameraIndex: Int? = nil) throws -> PoseTrack {
        let document = try JSONDecoder().decode(KeypointsDocument.self, from: data)
        let valid = document.frames.filter(\.valid)
        let cameras = Set(valid.map { $0.cameraIndex ?? 0 })
        guard let last = cameras.max() else { throw PoseTrackError.noValidFrames }
        let camera = cameraIndex ?? last
        let frames = valid.filter { ($0.cameraIndex ?? 0) == camera }
        guard !frames.isEmpty else { throw PoseTrackError.noFramesForCamera(camera) }
        var jointIndex: [String: Int] = [:]
        for (index, name) in document.jointOrder.enumerated() { jointIndex[name] = index }
        return PoseTrack(
            frames: frames.map(\.sourceFrame),
            timestamps: frames.map(\.timestampSeconds),
            jointsXY: frames.map { $0.joints.map { SIMD2($0.x ?? .nan, $0.y ?? .nan) } },
            jointScores: frames.map { $0.joints.map { $0.score ?? .nan } },
            jointIndex: jointIndex,
            boxes: frames.map { frame in
                guard let b = frame.bbox else { return SIMD4(repeating: .nan) }
                return SIMD4(b.x1 ?? .nan, b.y1 ?? .nan, b.x2 ?? .nan, b.y2 ?? .nan)
            }
        )
    }
}

/// The parts of keypoints_2d.json the analysis reads (same schema on server and phone).
struct KeypointsDocument: Decodable {
    struct Joint: Decodable {
        var x: Double?
        var y: Double?
        var score: Double?
    }

    struct Box: Decodable {
        var x1: Double?
        var y1: Double?
        var x2: Double?
        var y2: Double?
    }

    struct Frame: Decodable {
        var valid: Bool
        var cameraIndex: Int?
        var sourceFrame: Int
        var timestampSeconds: Double
        var joints: [Joint]
        var bbox: Box?

        enum CodingKeys: String, CodingKey {
            case valid, joints, bbox
            case cameraIndex = "camera_index"
            case sourceFrame = "source_frame"
            case timestampSeconds = "timestamp_seconds"
        }
    }

    var frames: [Frame]
    var jointOrder: [String]

    enum CodingKeys: String, CodingKey {
        case frames
        case jointOrder = "joint_order"
    }
}
