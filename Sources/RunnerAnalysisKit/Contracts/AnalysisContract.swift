import Foundation

public enum AnalysisContract {
    public static let schemaVersion = "1.0.0"
}

public enum ComputeLocation: String, Codable, Sendable {
    case server
    case local
}

public enum AnalysisKind: String, Codable, Sendable {
    case running
    case longJump = "long_jump"
}

public struct AnalysisVideo: Codable, Sendable, Equatable {
    public var uri: String
    public var sha256: String
    public var fps: Double
    public var width: Int
    public var height: Int
    public var frameCount: Int
    public var rotationDegrees: Int

    public init(
        uri: String,
        sha256: String,
        fps: Double,
        width: Int,
        height: Int,
        frameCount: Int,
        rotationDegrees: Int
    ) {
        self.uri = uri
        self.sha256 = sha256
        self.fps = fps
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.rotationDegrees = rotationDegrees
    }

    enum CodingKeys: String, CodingKey {
        case uri, sha256, fps, width, height
        case frameCount = "frame_count"
        case rotationDegrees = "rotation_degrees"
    }
}

public struct AnalysisCamera: Codable, Sendable, Equatable {
    public var cameraIndex: Int
    public var video: AnalysisVideo
    public var calibration: AnalysisCalibration?

    public init(cameraIndex: Int, video: AnalysisVideo, calibration: AnalysisCalibration? = nil) {
        self.cameraIndex = cameraIndex
        self.video = video
        self.calibration = calibration
    }

    enum CodingKeys: String, CodingKey {
        case cameraIndex = "camera_index"
        case video, calibration
    }
}

public struct AnalysisPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        x = try values.decode(Double.self)
        y = try values.decode(Double.self)
        guard values.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: values, debugDescription: "Point must have two values.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(x)
        try values.encode(y)
    }
}

public struct AnalysisCalibration: Codable, Sendable, Equatable {
    public var startLine: [AnalysisPoint]?
    public var endLine: [AnalysisPoint]?
    public var distanceM: Double?
    public var homographyImagePoints: [AnalysisPoint]?
    public var homographyWorldPointsM: [AnalysisPoint]?

    public init(
        startLine: [AnalysisPoint]? = nil,
        endLine: [AnalysisPoint]? = nil,
        distanceM: Double? = nil,
        homographyImagePoints: [AnalysisPoint]? = nil,
        homographyWorldPointsM: [AnalysisPoint]? = nil
    ) {
        self.startLine = startLine
        self.endLine = endLine
        self.distanceM = distanceM
        self.homographyImagePoints = homographyImagePoints
        self.homographyWorldPointsM = homographyWorldPointsM
    }

    enum CodingKeys: String, CodingKey {
        case startLine = "start_line"
        case endLine = "end_line"
        case distanceM = "distance_m"
        case homographyImagePoints = "homography_image_points"
        case homographyWorldPointsM = "homography_world_points_m"
    }
}

public struct AnalysisOutputPolicy: Codable, Sendable, Equatable {
    public var includePoseData: Bool
    public var includeOverlays: Bool

    public init(includePoseData: Bool = true, includeOverlays: Bool = false) {
        self.includePoseData = includePoseData
        self.includeOverlays = includeOverlays
    }

    enum CodingKeys: String, CodingKey {
        case includePoseData = "include_pose_data"
        case includeOverlays = "include_overlays"
    }
}

public struct AnalysisRequest: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var requestID: UUID
    public var analysisKind: AnalysisKind
    public var computeTargets: [ComputeLocation]
    public var cameras: [AnalysisCamera]
    public var outputPolicy: AnalysisOutputPolicy

    public init(
        schemaVersion: String = AnalysisContract.schemaVersion,
        requestID: UUID = UUID(),
        analysisKind: AnalysisKind,
        computeTargets: [ComputeLocation] = [.local],
        cameras: [AnalysisCamera],
        outputPolicy: AnalysisOutputPolicy = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.analysisKind = analysisKind
        self.computeTargets = computeTargets
        self.cameras = cameras
        self.outputPolicy = outputPolicy
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case analysisKind = "analysis_kind"
        case computeTargets = "compute_targets"
        case cameras
        case outputPolicy = "output_policy"
    }
}

public enum AnalysisStage: String, Codable, CaseIterable, Sendable {
    case validating, prescan, tracking, pose2d, pose3d, speed, gait, export, sync
    case completed, failed
}

public enum AnalysisEventStatus: String, Codable, Sendable {
    case started, progress, completed, skipped, failed
}

public struct AnalysisFailure: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var retriable: Bool

    public init(code: String, message: String, retriable: Bool) {
        self.code = code
        self.message = message
        self.retriable = retriable
    }
}

public enum AnalysisProgressUnit: String, Codable, Sendable {
    case fraction, frames, cameras, artifacts
}

public struct AnalysisProgress: Codable, Sendable, Equatable {
    public var completed: Double
    public var total: Double
    public var unit: AnalysisProgressUnit

    public init(completed: Double, total: Double, unit: AnalysisProgressUnit) {
        self.completed = completed
        self.total = total
        self.unit = unit
    }
}

public struct AnalysisEvent: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var eventID: UUID
    public var requestID: UUID
    public var runID: UUID
    public var computeLocation: ComputeLocation
    public var sequence: Int
    public var timestamp: Date
    public var stage: AnalysisStage
    public var status: AnalysisEventStatus
    public var message: String?
    public var progress: AnalysisProgress?
    public var error: AnalysisFailure?

    public init(
        schemaVersion: String = AnalysisContract.schemaVersion,
        eventID: UUID = UUID(),
        requestID: UUID,
        runID: UUID,
        computeLocation: ComputeLocation = .local,
        sequence: Int,
        timestamp: Date,
        stage: AnalysisStage,
        status: AnalysisEventStatus,
        message: String? = nil,
        progress: AnalysisProgress? = nil,
        error: AnalysisFailure? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.requestID = requestID
        self.runID = runID
        self.computeLocation = computeLocation
        self.sequence = sequence
        self.timestamp = timestamp
        self.stage = stage
        self.status = status
        self.message = message
        self.progress = progress
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventID = "event_id"
        case requestID = "request_id"
        case runID = "run_id"
        case computeLocation = "compute_location"
        case sequence, timestamp, stage, status, message, progress, error
    }
}

public enum AnalysisStageStatus: String, Codable, Sendable {
    case completed, skipped, failed
}

public enum AnalysisResultStage: String, Codable, Sendable {
    case validating, prescan, tracking, pose2d, pose3d, speed, gait, export, sync
}

public struct AnalysisStageResult: Codable, Sendable, Equatable {
    public var name: AnalysisResultStage
    public var status: AnalysisStageStatus
    public var durationSeconds: Double?
    public var warnings: [String]?

    public init(
        name: AnalysisResultStage,
        status: AnalysisStageStatus,
        durationSeconds: Double? = nil,
        warnings: [String]? = nil
    ) {
        self.name = name
        self.status = status
        self.durationSeconds = durationSeconds
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case name, status
        case durationSeconds = "duration_seconds"
        case warnings
    }
}

public struct AnalysisModelDescriptor: Codable, Sendable, Equatable {
    public var name: String
    public var sha256: String
    public var computeUnits: String?

    public init(name: String, sha256: String, computeUnits: String? = nil) {
        self.name = name
        self.sha256 = sha256
        self.computeUnits = computeUnits
    }

    enum CodingKeys: String, CodingKey {
        case name, sha256
        case computeUnits = "compute_units"
    }
}

public struct AnalysisEngineDescriptor: Codable, Sendable, Equatable {
    public var name: String
    public var version: String
    public var models: [AnalysisModelDescriptor]

    public init(name: String, version: String, models: [AnalysisModelDescriptor] = []) {
        self.name = name
        self.version = version
        self.models = models
    }
}

public struct AnalysisInputVideoDescriptor: Codable, Sendable, Equatable {
    public var cameraIndex: Int
    public var sha256: String

    public init(cameraIndex: Int, sha256: String) {
        self.cameraIndex = cameraIndex
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey {
        case cameraIndex = "camera_index"
        case sha256
    }
}

public struct AnalysisCoordinateSystem: Codable, Sendable, Equatable {
    public var pose2DOrigin = "top_left"
    public var xAxis = "right"
    public var yAxis = "down"
    public var pose2DUnit = "original_video_pixel"
    public var bboxFormat = "x1_y1_x2_y2"
    public var jointOrder: [String]

    public init(jointOrder: [String] = AnalysisCoordinateSystem.wholeBody23JointOrder) {
        self.jointOrder = jointOrder
    }

    public static let wholeBody23JointOrder = [
        "nose", "left_eye", "right_eye", "left_ear", "right_ear",
        "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
        "left_wrist", "right_wrist", "left_hip", "right_hip", "left_knee",
        "right_knee", "left_ankle", "right_ankle", "left_big_toe",
        "left_small_toe", "left_heel", "right_big_toe", "right_small_toe",
        "right_heel",
    ]

    enum CodingKeys: String, CodingKey {
        case pose2DOrigin = "pose2d_origin"
        case xAxis = "x_axis"
        case yAxis = "y_axis"
        case pose2DUnit = "pose2d_unit"
        case bboxFormat = "bbox_format"
        case jointOrder = "joint_order"
    }
}

public struct AnalysisSummary: Codable, Sendable, Equatable {
    public var totalTimeSeconds: Double
    public var averageSpeedMPS: Double?
    public var averageAccelerationMPS2: Double?
    public var detectedSteps: Int?
    public var averageCadenceSPM: Double?
    public var averageStepLengthM: Double?

    public init(totalTimeSeconds: Double = 0) {
        self.totalTimeSeconds = totalTimeSeconds
    }

    enum CodingKeys: String, CodingKey {
        case totalTimeSeconds = "total_time_seconds"
        case averageSpeedMPS = "average_speed_mps"
        case averageAccelerationMPS2 = "average_acceleration_mps2"
        case detectedSteps = "detected_steps"
        case averageCadenceSPM = "average_cadence_spm"
        case averageStepLengthM = "average_step_length_m"
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(totalTimeSeconds, forKey: .totalTimeSeconds)
        try values.encode(averageSpeedMPS, forKey: .averageSpeedMPS)
        try values.encode(averageAccelerationMPS2, forKey: .averageAccelerationMPS2)
        try values.encode(detectedSteps, forKey: .detectedSteps)
        try values.encode(averageCadenceSPM, forKey: .averageCadenceSPM)
        try values.encode(averageStepLengthM, forKey: .averageStepLengthM)
    }
}

public enum AnalysisResultStatus: String, Codable, Sendable {
    case completed, degraded, failed
}

public struct AnalysisResultManifest: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var requestID: UUID
    public var runID: UUID
    public var comparisonGroupID: UUID?
    public var computeLocation: ComputeLocation
    public var status: AnalysisResultStatus
    public var createdAt: Date
    public var configSha256: String
    public var engine: AnalysisEngineDescriptor
    public var inputVideos: [AnalysisInputVideoDescriptor]
    public var coordinateSystem: AnalysisCoordinateSystem
    public var stages: [AnalysisStageResult]
    public var summary: AnalysisSummary
    public var artifacts: [AnalysisArtifactDescriptor]
    public var warnings: [String]

    public init(
        requestID: UUID,
        runID: UUID,
        comparisonGroupID: UUID?,
        createdAt: Date,
        configSha256: String,
        inputVideos: [AnalysisInputVideoDescriptor],
        stages: [AnalysisStageResult],
        summary: AnalysisSummary = AnalysisSummary(),
        warnings: [String]
    ) {
        self.schemaVersion = AnalysisContract.schemaVersion
        self.requestID = requestID
        self.runID = runID
        self.comparisonGroupID = comparisonGroupID
        self.computeLocation = .local
        self.status = .degraded
        self.createdAt = createdAt
        self.configSha256 = configSha256
        self.engine = AnalysisEngineDescriptor(name: "RunnerAnalysisKit", version: "0.1.0-shell")
        self.inputVideos = inputVideos
        self.coordinateSystem = AnalysisCoordinateSystem()
        self.stages = stages
        self.summary = summary
        self.artifacts = []
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case runID = "run_id"
        case comparisonGroupID = "comparison_group_id"
        case computeLocation = "compute_location"
        case status
        case createdAt = "created_at"
        case configSha256 = "config_sha256"
        case engine
        case inputVideos = "input_videos"
        case coordinateSystem = "coordinate_system"
        case stages, summary, artifacts, warnings
    }
}

public enum AnalysisArtifactType: String, Codable, Sendable {
    case metrics, angles, steps, pose2d, pose3d, overlay, timing, diagnostics, other
}

public struct AnalysisArtifactDescriptor: Codable, Sendable, Equatable {
    public var artifactID: UUID
    public var type: AnalysisArtifactType
    public var mediaType: String
    public var relativePath: String
    public var sha256: String
    public var sizeBytes: Int
    public var cameraIndex: Int?

    public init(
        artifactID: UUID = UUID(),
        type: AnalysisArtifactType,
        mediaType: String,
        relativePath: String,
        sha256: String,
        sizeBytes: Int,
        cameraIndex: Int? = nil
    ) {
        self.artifactID = artifactID
        self.type = type
        self.mediaType = mediaType
        self.relativePath = relativePath
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.cameraIndex = cameraIndex
    }

    enum CodingKeys: String, CodingKey {
        case artifactID = "artifact_id"
        case type
        case mediaType = "media_type"
        case relativePath = "relative_path"
        case sha256
        case sizeBytes = "size_bytes"
        case cameraIndex = "camera_index"
    }
}

public struct Pose2DBoundingBox: Codable, Sendable, Equatable {
    public var x1: Double
    public var y1: Double
    public var x2: Double
    public var y2: Double

    public init(x1: Double, y1: Double, x2: Double, y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }
}

public struct Pose2DJoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var score: Double

    public init(x: Double, y: Double, score: Double) {
        self.x = x
        self.y = y
        self.score = score
    }
}

/// One frame in original, oriented video-pixel coordinates. Array position is
/// never used as a frame identifier; sourceFrame is explicit for parity with
/// the Server frame map.
public struct Pose2DFrame: Codable, Sendable, Equatable {
    public var cameraIndex: Int
    public var sourceFrame: Int
    public var timestampSeconds: Double
    public var bbox: Pose2DBoundingBox?
    public var joints: [Pose2DJoint]
    public var valid: Bool
    public var bboxExtrapolated: Bool

    public init(
        cameraIndex: Int,
        sourceFrame: Int,
        timestampSeconds: Double,
        bbox: Pose2DBoundingBox?,
        joints: [Pose2DJoint],
        valid: Bool,
        bboxExtrapolated: Bool
    ) {
        self.cameraIndex = cameraIndex
        self.sourceFrame = sourceFrame
        self.timestampSeconds = timestampSeconds
        self.bbox = bbox
        self.joints = joints
        self.valid = valid
        self.bboxExtrapolated = bboxExtrapolated
    }

    enum CodingKeys: String, CodingKey {
        case cameraIndex = "camera_index"
        case sourceFrame = "source_frame"
        case timestampSeconds = "timestamp_seconds"
        case bbox, joints, valid
        case bboxExtrapolated = "bbox_extrapolated"
    }
}

public struct Analysis2DResult: Sendable, Equatable {
    public var frames: [Pose2DFrame]
    public var durationSeconds: Double
    public var diagnosticsJSON: Data?
    /// Temporary HRNet-rendered video. The result store takes a copy into the
    /// bundle; the engine removes this temporary file after finalization.
    public var overlayVideoURL: URL?

    public init(
        frames: [Pose2DFrame],
        durationSeconds: Double,
        diagnosticsJSON: Data? = nil,
        overlayVideoURL: URL? = nil
    ) {
        self.frames = frames
        self.durationSeconds = durationSeconds
        self.diagnosticsJSON = diagnosticsJSON
        self.overlayVideoURL = overlayVideoURL
    }
}

public struct StoredAnalysisResult: Sendable, Equatable {
    public var bundleURL: URL
    public var manifest: AnalysisResultManifest

    public init(bundleURL: URL, manifest: AnalysisResultManifest) {
        self.bundleURL = bundleURL
        self.manifest = manifest
    }
}
