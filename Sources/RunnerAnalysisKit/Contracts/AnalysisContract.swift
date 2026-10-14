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
    public var roiX: [Double]?
    public var roiY: [Double]?

    public init(
        startLine: [AnalysisPoint]? = nil,
        endLine: [AnalysisPoint]? = nil,
        distanceM: Double? = nil,
        homographyImagePoints: [AnalysisPoint]? = nil,
        homographyWorldPointsM: [AnalysisPoint]? = nil,
        roiX: [Double]? = nil,
        roiY: [Double]? = nil
    ) {
        self.startLine = startLine
        self.endLine = endLine
        self.distanceM = distanceM
        self.homographyImagePoints = homographyImagePoints
        self.homographyWorldPointsM = homographyWorldPointsM
        self.roiX = roiX
        self.roiY = roiY
    }

    enum CodingKeys: String, CodingKey {
        case startLine = "start_line"
        case endLine = "end_line"
        case distanceM = "distance_m"
        case homographyImagePoints = "homography_image_points"
        case homographyWorldPointsM = "homography_world_points_m"
        case roiX = "roi_x"
        case roiY = "roi_y"
    }
}

public enum AnalysisSpeedMode: String, Codable, Sendable {
    case auto, pixel, homography
}

/// Numerical policy shared by Server and Local kinematics. Keeping these
/// values in the request makes a comparison reproducible instead of relying
/// on hidden per-platform constants.
public struct AnalysisKinematicsPolicy: Codable, Sendable, Equatable {
    public var speedMode: AnalysisSpeedMode
    public var butterworthCutoffHz: Double
    public var flatInterpolationEpsilonM: Double
    public var laneWidthM: Double

    public init(
        speedMode: AnalysisSpeedMode = .auto,
        butterworthCutoffHz: Double = 3.5,
        flatInterpolationEpsilonM: Double = 0.001,
        laneWidthM: Double = 1.22
    ) {
        self.speedMode = speedMode
        self.butterworthCutoffHz = butterworthCutoffHz
        self.flatInterpolationEpsilonM = flatInterpolationEpsilonM
        self.laneWidthM = laneWidthM
    }

    enum CodingKeys: String, CodingKey {
        case speedMode = "speed_mode"
        case butterworthCutoffHz = "butterworth_cutoff_hz"
        case flatInterpolationEpsilonM = "flat_interpolation_epsilon_m"
        case laneWidthM = "lane_width_m"
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
    public var kinematicsPolicy: AnalysisKinematicsPolicy

    public init(
        schemaVersion: String = AnalysisContract.schemaVersion,
        requestID: UUID = UUID(),
        analysisKind: AnalysisKind,
        computeTargets: [ComputeLocation] = [.local],
        cameras: [AnalysisCamera],
        outputPolicy: AnalysisOutputPolicy = .init(),
        kinematicsPolicy: AnalysisKinematicsPolicy = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.analysisKind = analysisKind
        self.computeTargets = computeTargets
        self.cameras = cameras
        self.outputPolicy = outputPolicy
        self.kinematicsPolicy = kinematicsPolicy
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case analysisKind = "analysis_kind"
        case computeTargets = "compute_targets"
        case cameras
        case outputPolicy = "output_policy"
        case kinematicsPolicy = "kinematics_policy"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(String.self, forKey: .schemaVersion)
        requestID = try values.decode(UUID.self, forKey: .requestID)
        analysisKind = try values.decode(AnalysisKind.self, forKey: .analysisKind)
        computeTargets = try values.decode([ComputeLocation].self, forKey: .computeTargets)
        cameras = try values.decode([AnalysisCamera].self, forKey: .cameras)
        outputPolicy = try values.decode(AnalysisOutputPolicy.self, forKey: .outputPolicy)
        kinematicsPolicy = try values.decodeIfPresent(
            AnalysisKinematicsPolicy.self,
            forKey: .kinematicsPolicy
        ) ?? AnalysisKinematicsPolicy()
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
    public var maximumSpeedMPS: Double?
    public var officialJumpDistanceM: Double?
    public var takeoffSpeedMPS: Double?
    public var flightTimeSeconds: Double?

    public init(
        totalTimeSeconds: Double = 0,
        averageSpeedMPS: Double? = nil,
        averageAccelerationMPS2: Double? = nil,
        detectedSteps: Int? = nil,
        averageCadenceSPM: Double? = nil,
        averageStepLengthM: Double? = nil,
        maximumSpeedMPS: Double? = nil,
        officialJumpDistanceM: Double? = nil,
        takeoffSpeedMPS: Double? = nil,
        flightTimeSeconds: Double? = nil
    ) {
        self.totalTimeSeconds = totalTimeSeconds
        self.averageSpeedMPS = averageSpeedMPS
        self.averageAccelerationMPS2 = averageAccelerationMPS2
        self.detectedSteps = detectedSteps
        self.averageCadenceSPM = averageCadenceSPM
        self.averageStepLengthM = averageStepLengthM
        self.maximumSpeedMPS = maximumSpeedMPS
        self.officialJumpDistanceM = officialJumpDistanceM
        self.takeoffSpeedMPS = takeoffSpeedMPS
        self.flightTimeSeconds = flightTimeSeconds
    }

    enum CodingKeys: String, CodingKey {
        case totalTimeSeconds = "total_time_seconds"
        case averageSpeedMPS = "average_speed_mps"
        case averageAccelerationMPS2 = "average_acceleration_mps2"
        case detectedSteps = "detected_steps"
        case averageCadenceSPM = "average_cadence_spm"
        case averageStepLengthM = "average_step_length_m"
        case maximumSpeedMPS = "maximum_speed_mps"
        case officialJumpDistanceM = "official_jump_distance_m"
        case takeoffSpeedMPS = "takeoff_speed_mps"
        case flightTimeSeconds = "flight_time_seconds"
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(totalTimeSeconds, forKey: .totalTimeSeconds)
        try values.encode(averageSpeedMPS, forKey: .averageSpeedMPS)
        try values.encode(averageAccelerationMPS2, forKey: .averageAccelerationMPS2)
        try values.encode(detectedSteps, forKey: .detectedSteps)
        try values.encode(averageCadenceSPM, forKey: .averageCadenceSPM)
        try values.encode(averageStepLengthM, forKey: .averageStepLengthM)
        try values.encode(maximumSpeedMPS, forKey: .maximumSpeedMPS)
        try values.encode(officialJumpDistanceM, forKey: .officialJumpDistanceM)
        try values.encode(takeoffSpeedMPS, forKey: .takeoffSpeedMPS)
        try values.encode(flightTimeSeconds, forKey: .flightTimeSeconds)
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
        engine: AnalysisEngineDescriptor = AnalysisEngineDescriptor(
            name: "RunnerAnalysisKit",
            version: "0.1.0-shell"
        ),
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
        self.engine = engine
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
    case metrics, angles, steps, contacts, pose2d, pose3d, overlay, timing, diagnostics, other
    case legIdentity = "leg_identity"
    case longJump = "long_jump"
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
    /// Per-frame timing, thermal state and memory footprint diagnostics.
    public var perFrameDiagnosticsCSV: Data?
    /// Temporary HRNet-rendered video. The result store takes a copy into the
    /// bundle; the engine removes this temporary file after finalization.
    public var overlayVideoURL: URL?
    /// Model files that produced these poses (detector + HRNet).
    public var models: [AnalysisModelDescriptor]

    public init(
        frames: [Pose2DFrame],
        durationSeconds: Double,
        diagnosticsJSON: Data? = nil,
        perFrameDiagnosticsCSV: Data? = nil,
        overlayVideoURL: URL? = nil,
        models: [AnalysisModelDescriptor] = []
    ) {
        self.frames = frames
        self.durationSeconds = durationSeconds
        self.diagnosticsJSON = diagnosticsJSON
        self.perFrameDiagnosticsCSV = perFrameDiagnosticsCSV
        self.overlayVideoURL = overlayVideoURL
        self.models = models
    }
}

public struct Pose3DJoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// MotionAGFormer output in H36M17 order. Source identity is retained from
/// Pose2DFrame so padding and clip boundaries never become implicit frame IDs.
public struct Pose3DFrame: Codable, Sendable, Equatable {
    public var cameraIndex: Int
    public var sourceFrame: Int
    public var timestampSeconds: Double
    public var joints: [Pose3DJoint]

    public init(
        cameraIndex: Int,
        sourceFrame: Int,
        timestampSeconds: Double,
        joints: [Pose3DJoint]
    ) {
        self.cameraIndex = cameraIndex
        self.sourceFrame = sourceFrame
        self.timestampSeconds = timestampSeconds
        self.joints = joints
    }

    enum CodingKeys: String, CodingKey {
        case cameraIndex = "camera_index"
        case sourceFrame = "source_frame"
        case timestampSeconds = "timestamp_seconds"
        case joints
    }
}

public struct Pose3DArtifactDocument: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var jointOrder: [String]
    public var frames: [Pose3DFrame]

    public init(
        schemaVersion: String = AnalysisContract.schemaVersion,
        jointOrder: [String] = Self.h36m17JointOrder,
        frames: [Pose3DFrame]
    ) {
        self.schemaVersion = schemaVersion
        self.jointOrder = jointOrder
        self.frames = frames
    }

    public static let h36m17JointOrder = [
        "pelvis", "right_hip", "right_knee", "right_ankle",
        "left_hip", "left_knee", "left_ankle", "spine", "thorax",
        "neck_nose", "head", "left_shoulder", "left_elbow", "left_wrist",
        "right_shoulder", "right_elbow", "right_wrist",
    ]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case jointOrder = "joint_order"
        case frames
    }
}

public struct AnalysisAngleFrame: Codable, Sendable, Equatable {
    public var cameraIndex: Int
    public var sourceFrame: Int
    public var timestampSeconds: Double
    public var rawValuesDegrees: [String: Double]?
    public var valuesDegrees: [String: Double]

    public init(
        cameraIndex: Int,
        sourceFrame: Int,
        timestampSeconds: Double,
        rawValuesDegrees: [String: Double]? = nil,
        valuesDegrees: [String: Double]
    ) {
        self.cameraIndex = cameraIndex
        self.sourceFrame = sourceFrame
        self.timestampSeconds = timestampSeconds
        self.rawValuesDegrees = rawValuesDegrees
        self.valuesDegrees = valuesDegrees
    }

    enum CodingKeys: String, CodingKey {
        case cameraIndex = "camera_index"
        case sourceFrame = "source_frame"
        case timestampSeconds = "timestamp_seconds"
        case rawValuesDegrees = "raw_values_degrees"
        case valuesDegrees = "values_degrees"
    }
}

public struct AnalysisAnglesArtifactDocument: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var frames: [AnalysisAngleFrame]

    public init(
        schemaVersion: String = AnalysisContract.schemaVersion,
        frames: [AnalysisAngleFrame]
    ) {
        self.schemaVersion = schemaVersion
        self.frames = frames
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case frames
    }
}

public struct Analysis3DResult: Sendable, Equatable {
    public var frames: [Pose3DFrame]
    public var angles: [AnalysisAngleFrame]
    public var durationSeconds: Double
    public var warnings: [String]
    /// Model files that produced these poses (MotionAGFormer).
    public var models: [AnalysisModelDescriptor]

    public init(
        frames: [Pose3DFrame],
        angles: [AnalysisAngleFrame],
        durationSeconds: Double,
        warnings: [String] = [],
        models: [AnalysisModelDescriptor] = []
    ) {
        self.frames = frames
        self.angles = angles
        self.durationSeconds = durationSeconds
        self.warnings = warnings
        self.models = models
    }
}

/// One Server-compatible distance/speed/acceleration sample. Distances are
/// cumulative across camera hand-offs and retain their original frame identity.
public struct AnalysisKinematicsFrame: Codable, Sendable, Equatable {
    public var cameraIndex: Int
    public var cameraFrame: Int
    public var sourceFrame: Int
    public var absoluteFrame: Int
    public var timestampSeconds: Double
    public var distanceM: Double
    public var rawDistanceM: Double?
    public var smoothDistanceM: Double
    public var speedMPS: Double
    public var accelerationMPS2: Double
    public var speedModeUsed: String
    public var pixelDistanceM: Double?
    public var pixelSpeedMPS: Double?
    public var pixelAccelerationMPS2: Double?
    public var homographyDistanceM: Double?
    public var homographySpeedMPS: Double?
    public var homographyAccelerationMPS2: Double?
    public var imagePointX: Double
    public var imagePointY: Double
    public var isInterpolated: Bool
    public var interpolationGapLength: Int
    public var confidence: Double

    enum CodingKeys: String, CodingKey {
        case cameraIndex = "camera_index"
        case cameraFrame = "camera_frame"
        case sourceFrame = "source_frame"
        case absoluteFrame = "absolute_frame"
        case timestampSeconds = "timestamp_seconds"
        case distanceM = "distance_m"
        case rawDistanceM = "raw_distance_m"
        case smoothDistanceM = "smooth_distance_m"
        case speedMPS = "speed_mps"
        case accelerationMPS2 = "acceleration_mps2"
        case speedModeUsed = "speed_mode_used"
        case pixelDistanceM = "pixel_distance_m"
        case pixelSpeedMPS = "pixel_speed_mps"
        case pixelAccelerationMPS2 = "pixel_acceleration_mps2"
        case homographyDistanceM = "homography_distance_m"
        case homographySpeedMPS = "homography_speed_mps"
        case homographyAccelerationMPS2 = "homography_acceleration_mps2"
        case imagePointX = "image_point_x"
        case imagePointY = "image_point_y"
        case isInterpolated = "is_interpolated"
        case interpolationGapLength = "interpolation_gap_length"
        case confidence
    }

    /// The kinematics schema requires every key; synthesized Codable would
    /// drop nil series (e.g. pixel_* when homography is used) instead of
    /// writing null.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(cameraIndex, forKey: .cameraIndex)
        try values.encode(cameraFrame, forKey: .cameraFrame)
        try values.encode(sourceFrame, forKey: .sourceFrame)
        try values.encode(absoluteFrame, forKey: .absoluteFrame)
        try values.encode(timestampSeconds, forKey: .timestampSeconds)
        try values.encode(distanceM, forKey: .distanceM)
        try values.encode(rawDistanceM, forKey: .rawDistanceM)
        try values.encode(smoothDistanceM, forKey: .smoothDistanceM)
        try values.encode(speedMPS, forKey: .speedMPS)
        try values.encode(accelerationMPS2, forKey: .accelerationMPS2)
        try values.encode(speedModeUsed, forKey: .speedModeUsed)
        try values.encode(pixelDistanceM, forKey: .pixelDistanceM)
        try values.encode(pixelSpeedMPS, forKey: .pixelSpeedMPS)
        try values.encode(pixelAccelerationMPS2, forKey: .pixelAccelerationMPS2)
        try values.encode(homographyDistanceM, forKey: .homographyDistanceM)
        try values.encode(homographySpeedMPS, forKey: .homographySpeedMPS)
        try values.encode(homographyAccelerationMPS2, forKey: .homographyAccelerationMPS2)
        try values.encode(imagePointX, forKey: .imagePointX)
        try values.encode(imagePointY, forKey: .imagePointY)
        try values.encode(isInterpolated, forKey: .isInterpolated)
        try values.encode(interpolationGapLength, forKey: .interpolationGapLength)
        try values.encode(confidence, forKey: .confidence)
    }
}

public struct AnalysisKinematicsArtifactDocument: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var frames: [AnalysisKinematicsFrame]

    public init(
        schemaVersion: String = AnalysisContract.schemaVersion,
        frames: [AnalysisKinematicsFrame]
    ) {
        self.schemaVersion = schemaVersion
        self.frames = frames
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case frames
    }
}

public struct AnalysisKinematicsResult: Sendable, Equatable {
    public var frames: [AnalysisKinematicsFrame]
    public var durationSeconds: Double
    public var warnings: [String]

    public init(
        frames: [AnalysisKinematicsFrame],
        durationSeconds: Double,
        warnings: [String] = []
    ) {
        self.frames = frames
        self.durationSeconds = durationSeconds
        self.warnings = warnings
    }

    public var averageSpeedMPS: Double? {
        guard !frames.isEmpty else { return nil }
        return frames.map(\.speedMPS).reduce(0, +) / Double(frames.count)
    }

    public var averageAccelerationMPS2: Double? {
        guard !frames.isEmpty else { return nil }
        return frames.map(\.accelerationMPS2).reduce(0, +) / Double(frames.count)
    }

    public var maximumSpeedMPS: Double? {
        frames.map(\.speedMPS).max()
    }
}

public enum AnalysisDetectedLegSource: String, Codable, Sendable {
    case detectedLeft = "detected_left"
    case detectedRight = "detected_right"
}

public enum AnalysisLegIdentityReason: String, Codable, Sendable {
    case none
    case temporalDP = "temporal_dp"
    case anchor, geometry, manual
}

public struct AnalysisLegIdentityFrame: Codable, Sendable, Equatable {
    public var cameraIndex: Int
    public var sourceFrame: Int
    public var timestampSeconds: Double
    public var leftSource: AnalysisDetectedLegSource
    public var rightSource: AnalysisDetectedLegSource
    public var swapped: Bool
    public var confidence: Double
    public var reason: AnalysisLegIdentityReason

    public init(
        cameraIndex: Int,
        sourceFrame: Int,
        timestampSeconds: Double,
        leftSource: AnalysisDetectedLegSource,
        rightSource: AnalysisDetectedLegSource,
        swapped: Bool,
        confidence: Double,
        reason: AnalysisLegIdentityReason
    ) {
        self.cameraIndex = cameraIndex
        self.sourceFrame = sourceFrame
        self.timestampSeconds = timestampSeconds
        self.leftSource = leftSource
        self.rightSource = rightSource
        self.swapped = swapped
        self.confidence = confidence
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case cameraIndex = "camera_index"
        case sourceFrame = "source_frame"
        case timestampSeconds = "timestamp_seconds"
        case leftSource = "left_source"
        case rightSource = "right_source"
        case swapped, confidence, reason
    }
}

public struct AnalysisLegIdentityArtifactDocument: Codable, Sendable, Equatable {
    public var schemaVersion: String = AnalysisContract.schemaVersion
    public var frames: [AnalysisLegIdentityFrame]

    public init(frames: [AnalysisLegIdentityFrame]) { self.frames = frames }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case frames
    }
}

public enum AnalysisFoot: String, Codable, Sendable {
    case left, right, bilateral, unknown
}

public enum AnalysisContactEventType: String, Codable, Sendable {
    case heelStrike = "heel_strike"
    case toeStrike = "toe_strike"
    case footFlat = "foot_flat"
    case toeOff = "toe_off"
    case touchdown, takeoff
    case firstAirborne = "first_airborne"
    case finalLanding = "final_landing"
}

public enum AnalysisContactJoint: String, Codable, Sendable {
    case heel
    case bigToe = "big_toe"
    case smallToe = "small_toe"
    case ankle, unknown
}

public struct AnalysisContactEvent: Codable, Sendable, Equatable {
    public var eventIndex: Int
    public var eventType: AnalysisContactEventType
    public var foot: AnalysisFoot
    public var cameraIndex: Int
    public var sourceFrame: Int
    public var timestampSeconds: Double
    public var contactJoint: AnalysisContactJoint
    public var imagePoint: AnalysisPoint?
    public var worldPointM: AnalysisPoint?
    public var confidence: Double
    public var reason: String

    public init(
        eventIndex: Int,
        eventType: AnalysisContactEventType,
        foot: AnalysisFoot,
        cameraIndex: Int,
        sourceFrame: Int,
        timestampSeconds: Double,
        contactJoint: AnalysisContactJoint,
        imagePoint: AnalysisPoint? = nil,
        worldPointM: AnalysisPoint? = nil,
        confidence: Double,
        reason: String
    ) {
        self.eventIndex = eventIndex
        self.eventType = eventType
        self.foot = foot
        self.cameraIndex = cameraIndex
        self.sourceFrame = sourceFrame
        self.timestampSeconds = timestampSeconds
        self.contactJoint = contactJoint
        self.imagePoint = imagePoint
        self.worldPointM = worldPointM
        self.confidence = confidence
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case eventIndex = "event_index"
        case eventType = "event_type"
        case foot
        case cameraIndex = "camera_index"
        case sourceFrame = "source_frame"
        case timestampSeconds = "timestamp_seconds"
        case contactJoint = "contact_joint"
        case imagePoint = "image_point"
        case worldPointM = "world_point_m"
        case confidence, reason
    }
}

public struct AnalysisContactEventsArtifactDocument: Codable, Sendable, Equatable {
    public var schemaVersion: String = AnalysisContract.schemaVersion
    public var events: [AnalysisContactEvent]

    public init(events: [AnalysisContactEvent]) { self.events = events }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case events
    }
}

public enum AnalysisStepEventType: String, Codable, Sendable {
    case step, takeoff
    case finalLanding = "final_landing"
}

public struct AnalysisStepSample: Codable, Sendable, Equatable {
    public var stepIndex: Int
    public var eventType: AnalysisStepEventType
    public var foot: AnalysisFoot
    public var cameraIndex: Int
    public var sourceFrame: Int
    public var timestampSeconds: Double
    public var worldXM: Double?
    public var worldYM: Double?
    public var stepLengthM: Double?
    public var strideLengthM: Double?
    public var contactTimeSeconds: Double?
    public var speedMPS: Double?
    public var confidence: Double

    public init(
        stepIndex: Int,
        eventType: AnalysisStepEventType,
        foot: AnalysisFoot,
        cameraIndex: Int,
        sourceFrame: Int,
        timestampSeconds: Double,
        worldXM: Double? = nil,
        worldYM: Double? = nil,
        stepLengthM: Double? = nil,
        strideLengthM: Double? = nil,
        contactTimeSeconds: Double? = nil,
        speedMPS: Double? = nil,
        confidence: Double
    ) {
        self.stepIndex = stepIndex
        self.eventType = eventType
        self.foot = foot
        self.cameraIndex = cameraIndex
        self.sourceFrame = sourceFrame
        self.timestampSeconds = timestampSeconds
        self.worldXM = worldXM
        self.worldYM = worldYM
        self.stepLengthM = stepLengthM
        self.strideLengthM = strideLengthM
        self.contactTimeSeconds = contactTimeSeconds
        self.speedMPS = speedMPS
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case stepIndex = "step_index"
        case eventType = "event_type"
        case foot
        case cameraIndex = "camera_index"
        case sourceFrame = "source_frame"
        case timestampSeconds = "timestamp_seconds"
        case worldXM = "world_x_m"
        case worldYM = "world_y_m"
        case stepLengthM = "step_length_m"
        case strideLengthM = "stride_length_m"
        case contactTimeSeconds = "contact_time_seconds"
        case speedMPS = "speed_mps"
        case confidence
    }
}

public struct AnalysisStepsArtifactDocument: Codable, Sendable, Equatable {
    public var schemaVersion: String = AnalysisContract.schemaVersion
    public var averageStepLengthM: Double?
    public var averageStrideLengthM: Double?
    public var averageCadenceSPM: Double?
    public var steps: [AnalysisStepSample]

    public init(
        averageStepLengthM: Double? = nil,
        averageStrideLengthM: Double? = nil,
        averageCadenceSPM: Double? = nil,
        steps: [AnalysisStepSample]
    ) {
        self.averageStepLengthM = averageStepLengthM
        self.averageStrideLengthM = averageStrideLengthM
        self.averageCadenceSPM = averageCadenceSPM
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case averageStepLengthM = "average_step_length_m"
        case averageStrideLengthM = "average_stride_length_m"
        case averageCadenceSPM = "average_cadence_spm"
        case steps
    }
}

public struct AnalysisLongJumpEventReference: Codable, Sendable, Equatable {
    public var cameraIndex: Int
    public var sourceFrame: Int
    public var timestampSeconds: Double
    public var foot: AnalysisFoot
    public var worldXM: Double?

    public init(
        cameraIndex: Int,
        sourceFrame: Int,
        timestampSeconds: Double,
        foot: AnalysisFoot,
        worldXM: Double? = nil
    ) {
        self.cameraIndex = cameraIndex
        self.sourceFrame = sourceFrame
        self.timestampSeconds = timestampSeconds
        self.foot = foot
        self.worldXM = worldXM
    }

    enum CodingKeys: String, CodingKey {
        case cameraIndex = "camera_index"
        case sourceFrame = "source_frame"
        case timestampSeconds = "timestamp_seconds"
        case foot
        case worldXM = "world_x_m"
    }
}

public enum AnalysisLongJumpStatus: String, Codable, Sendable {
    case completed, degraded, unavailable
}

public struct AnalysisLongJumpResultArtifactDocument: Codable, Sendable, Equatable {
    public var schemaVersion: String = AnalysisContract.schemaVersion
    public var status: AnalysisLongJumpStatus
    public var officialDistanceM: Double?
    public var takeoff: AnalysisLongJumpEventReference?
    public var landing: AnalysisLongJumpEventReference?
    public var takeoffSpeedMPS: Double?
    public var flightTimeSeconds: Double?
    public var foul: Bool?
    public var confidence: Double?
    public var warnings: [String]

    public init(
        status: AnalysisLongJumpStatus,
        officialDistanceM: Double? = nil,
        takeoff: AnalysisLongJumpEventReference? = nil,
        landing: AnalysisLongJumpEventReference? = nil,
        takeoffSpeedMPS: Double? = nil,
        flightTimeSeconds: Double? = nil,
        foul: Bool? = nil,
        confidence: Double? = nil,
        warnings: [String] = []
    ) {
        self.status = status
        self.officialDistanceM = officialDistanceM
        self.takeoff = takeoff
        self.landing = landing
        self.takeoffSpeedMPS = takeoffSpeedMPS
        self.flightTimeSeconds = flightTimeSeconds
        self.foul = foul
        self.confidence = confidence
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case status
        case officialDistanceM = "official_distance_m"
        case takeoff, landing
        case takeoffSpeedMPS = "takeoff_speed_mps"
        case flightTimeSeconds = "flight_time_seconds"
        case foul, confidence, warnings
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
