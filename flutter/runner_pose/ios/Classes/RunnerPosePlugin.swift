import AVFoundation
import CryptoKit
import Flutter
import Foundation
import RunnerAnalysisKit
import UIKit

// FlutterError is bridged through Swift Result APIs by the generated Pigeon
// host interface. Flutter does not currently declare Error conformance, so
// provide it once in the plugin instead of requiring each Mac checkout to
// carry an uncommitted compatibility patch.
extension FlutterError: @retroactive Error {}

public final class RunnerPosePlugin: NSObject, FlutterPlugin, RunnerAnalysisHostApi {
    private let flutterAPI: RunnerAnalysisFlutterApi
    private var analysisEngine: RunnerAnalysisEngine?
    private var analysisTask: Task<Void, Never>?
    private var motion3DProcessor: MotionAGFormer3DProcessor?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    private init(binaryMessenger: FlutterBinaryMessenger) {
        flutterAPI = RunnerAnalysisFlutterApi(binaryMessenger: binaryMessenger)
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = RunnerPosePlugin(binaryMessenger: registrar.messenger())
        RunnerAnalysisHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    }

    func startAnalysis(
        request: RunnerAnalysisRequestMessage,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard analysisTask == nil else {
            completion(.failure(BridgeError.analysisAlreadyRunning))
            return
        }

        analysisTask = Task { [weak self] in
            guard let self else { return }
            await beginBackgroundTask()
            do {
                let mapped = try await Self.map(request)
                let resultStore = LocalAnalysisResultStore(rootURL: mapped.outputDirectory)
                let pose3DProcessor: (any Analysis3DProcessing)?
                if CoreMLMotionAGFormerPredictor.isBundled {
                    if motion3DProcessor == nil {
                        motion3DProcessor = MotionAGFormer3DProcessor(
                            predictor: try CoreMLMotionAGFormerPredictor.bundled()
                        )
                    }
                    pose3DProcessor = motion3DProcessor
                } else {
                    pose3DProcessor = nil
                }
                let engine = RunnerAnalysisEngine(
                    pose2D: RunnerPose2DAdapter(),
                    pose3D: pose3DProcessor,
                    storage: resultStore
                )
                analysisEngine = engine
                completion(.success(()))

                let stream = await engine.analyze(
                    mapped.request,
                    comparisonGroupID: mapped.comparisonGroupID
                )
                for await event in stream {
                    await send(Self.message(event))
                }
            } catch {
                completion(.failure(error))
            }
            analysisEngine = nil
            analysisTask = nil
            await endBackgroundTask()
        }
    }

    func cancelAnalysis(completion: @escaping (Result<Void, Error>) -> Void) {
        Task { [weak self] in
            guard let self else {
                completion(.success(()))
                return
            }
            if let analysisEngine {
                await analysisEngine.cancel()
            } else {
                analysisTask?.cancel()
            }
            completion(.success(()))
        }
    }

    func dispose(completion: @escaping (Result<Void, Error>) -> Void) {
        Task { [weak self] in
            guard let self else {
                completion(.success(()))
                return
            }
            await analysisEngine?.cancel()
            _ = await analysisTask?.value
            analysisTask = nil
            analysisEngine = nil
            await endBackgroundTask()
            completion(.success(()))
        }
    }

    func extractFirstFrame(
        videoPath: String,
        completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            do {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: videoPath)))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let image = try await generator.image(at: .zero).image
                guard let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else {
                    throw BridgeError.invalidVideo("Could not encode first frame: \(videoPath)")
                }
                completion(.success(FlutterStandardTypedData(bytes: jpeg)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Flutter platform-channel calls must originate on the platform thread.
    /// Pigeon does not marshal FlutterApi calls for us; without MainActor
    /// isolation the final `completed` event can be dropped, leaving Dart
    /// waiting forever even though the native pipeline has finished.
    private func send(_ event: RunnerAnalysisEventMessage) async {
        await withCheckedContinuation { continuation in
            // Flutter's iOS binary messenger requires an actual dispatch to
            // the main queue. MainActor isolation alone is not sufficient in
            // every Swift/Flutter toolchain combination and can still trigger
            // the "non-platform thread" warning on a physical device.
            DispatchQueue.main.async { [flutterAPI] in
                flutterAPI.onEvent(event: event) { _ in continuation.resume() }
            }
        }
    }

    private func beginBackgroundTask() async {
        await MainActor.run {
            guard backgroundTask == .invalid else { return }
            backgroundTask = UIApplication.shared.beginBackgroundTask(
                withName: "RunnerAnalysis"
            ) { [weak self] in
                Task {
                    await self?.analysisEngine?.cancel()
                    await self?.endBackgroundTask()
                }
            }
        }
    }

    private func endBackgroundTask() async {
        await MainActor.run {
            guard backgroundTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}

private extension RunnerPosePlugin {
    struct MappedRequest {
        var request: AnalysisRequest
        var comparisonGroupID: UUID?
        var outputDirectory: URL
    }

    enum BridgeError: LocalizedError {
        case analysisAlreadyRunning
        case invalidRequestID(String)
        case invalidComparisonGroupID(String)
        case invalidAnalysisKind(String)
        case invalidVideo(String)
        case invalidCalibration(String)

        var errorDescription: String? {
            switch self {
            case .analysisAlreadyRunning:
                return "A local analysis is already running."
            case .invalidRequestID(let value):
                return "requestId is not a UUID: \(value)"
            case .invalidComparisonGroupID(let value):
                return "comparisonGroupId is not a UUID: \(value)"
            case .invalidAnalysisKind(let value):
                return "analysisKind is unsupported: \(value)"
            case .invalidVideo(let message):
                return message
            case .invalidCalibration(let message):
                return message
            }
        }
    }

    static func map(_ message: RunnerAnalysisRequestMessage) async throws -> MappedRequest {
        guard let requestID = UUID(uuidString: message.requestId) else {
            throw BridgeError.invalidRequestID(message.requestId)
        }
        let comparisonGroupID: UUID?
        if let value = message.comparisonGroupId {
            guard let parsed = UUID(uuidString: value) else {
                throw BridgeError.invalidComparisonGroupID(value)
            }
            comparisonGroupID = parsed
        } else {
            comparisonGroupID = nil
        }
        let analysisKind: AnalysisKind
        switch message.analysisKind {
        case "running":
            analysisKind = .running
        case "long_jump":
            analysisKind = .longJump
        default:
            throw BridgeError.invalidAnalysisKind(message.analysisKind)
        }
        let videos = try message.videos.enumerated().map { offset, video -> RunnerAnalysisVideoMessage in
            guard let video else {
                throw BridgeError.invalidVideo("videos[\(offset)] must not be null.")
            }
            return video
        }
        guard !videos.isEmpty else {
            throw BridgeError.invalidVideo("At least one video path is required.")
        }

        var cameras: [AnalysisCamera] = []
        cameras.reserveCapacity(videos.count)
        for video in videos {
            let url = URL(fileURLWithPath: video.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw BridgeError.invalidVideo("Input video does not exist: \(url.path)")
            }
            guard video.fps > 0 else {
                throw BridgeError.invalidVideo("Video fps must be positive: \(url.path)")
            }
            let digest = try await fileSHA256(url)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let dimensions = try await videoDimensions(
                asset: asset,
                suppliedWidth: Int(video.width),
                suppliedHeight: Int(video.height)
            )
            let frameCount = max(1, Int((duration * video.fps).rounded()))
            let calibration = try mapCalibration(
                video.calibration,
                frameWidth: Double(dimensions.width),
                frameHeight: Double(dimensions.height)
            )
            cameras.append(AnalysisCamera(
                cameraIndex: Int(video.cameraIndex),
                video: AnalysisVideo(
                    uri: url.absoluteString,
                    sha256: digest,
                    fps: video.fps,
                    width: dimensions.width,
                    height: dimensions.height,
                    frameCount: frameCount,
                    rotationDegrees: Int(video.rotationDegrees)
                ),
                calibration: calibration
            ))
        }

        let outputDirectory: URL
        if message.outputDirectoryPath.isEmpty {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            outputDirectory = applicationSupport.appendingPathComponent(
                "RunnerAnalysisResults",
                isDirectory: true
            )
        } else {
            outputDirectory = URL(fileURLWithPath: message.outputDirectoryPath, isDirectory: true)
        }

        let speedMode: AnalysisSpeedMode
        switch message.kinematicsPolicy.speedMode {
        case "auto": speedMode = .auto
        case "pixel": speedMode = .pixel
        case "homography": speedMode = .homography
        default:
            throw BridgeError.invalidCalibration(
                "kinematicsPolicy.speedMode must be auto, pixel, or homography."
            )
        }
        guard message.kinematicsPolicy.butterworthCutoffHz > 0,
              message.kinematicsPolicy.flatInterpolationEpsilonM >= 0,
              message.kinematicsPolicy.laneWidthM > 0 else {
            throw BridgeError.invalidCalibration(
                "Kinematics cutoff/lane width must be positive and flat epsilon non-negative."
            )
        }

        return MappedRequest(
            request: AnalysisRequest(
                schemaVersion: message.schemaVersion,
                requestID: requestID,
                analysisKind: analysisKind,
                cameras: cameras,
                outputPolicy: AnalysisOutputPolicy(includeOverlays: message.includeOverlays),
                kinematicsPolicy: AnalysisKinematicsPolicy(
                    speedMode: speedMode,
                    butterworthCutoffHz: message.kinematicsPolicy.butterworthCutoffHz,
                    flatInterpolationEpsilonM:
                        message.kinematicsPolicy.flatInterpolationEpsilonM,
                    laneWidthM: message.kinematicsPolicy.laneWidthM
                )
            ),
            comparisonGroupID: comparisonGroupID,
            outputDirectory: outputDirectory
        )
    }

    static func mapCalibration(
        _ message: RunnerAnalysisCalibrationMessage?,
        frameWidth: Double,
        frameHeight: Double
    ) throws -> AnalysisCalibration? {
        guard let message else { return nil }
        // Normalized anchors become original-video pixels here, using the same
        // oriented dimensions the 2D pipeline reports keypoints in.
        let scaleX = message.imagePointsNormalized == true ? frameWidth : 1
        let scaleY = message.imagePointsNormalized == true ? frameHeight : 1

        func points(
            _ values: [RunnerAnalysisPointMessage?]?,
            field: String,
            scaleX: Double = 1,
            scaleY: Double = 1
        ) throws -> [AnalysisPoint]? {
            guard let values else { return nil }
            return try values.enumerated().map { index, value in
                guard let value else {
                    throw BridgeError.invalidCalibration(
                        "\(field)[\(index)] must not be null."
                    )
                }
                return AnalysisPoint(x: value.x * scaleX, y: value.y * scaleY)
            }
        }

        func numbers(_ values: [Double?]?, field: String, scale: Double) throws -> [Double]? {
            guard let values else { return nil }
            return try values.enumerated().map { index, value in
                guard let value else {
                    throw BridgeError.invalidCalibration(
                        "\(field)[\(index)] must not be null."
                    )
                }
                return value * scale
            }
        }

        let startLine = try points(
            message.startLine, field: "startLine", scaleX: scaleX, scaleY: scaleY
        )
        let endLine = try points(
            message.endLine, field: "endLine", scaleX: scaleX, scaleY: scaleY
        )
        let imagePoints = try points(
            message.homographyImagePoints,
            field: "homographyImagePoints",
            scaleX: scaleX,
            scaleY: scaleY
        )
        let worldPoints = try points(
            message.homographyWorldPointsM,
            field: "homographyWorldPointsM"
        )
        let roiX = try numbers(message.roiX, field: "roiX", scale: scaleX)
        let roiY = try numbers(message.roiY, field: "roiY", scale: scaleY)
        if let startLine, startLine.count != 2 {
            throw BridgeError.invalidCalibration("startLine must contain exactly two points.")
        }
        if let endLine, endLine.count != 2 {
            throw BridgeError.invalidCalibration("endLine must contain exactly two points.")
        }
        if imagePoints?.count != worldPoints?.count {
            throw BridgeError.invalidCalibration(
                "Homography image/world point counts must match."
            )
        }
        if roiX?.count != roiY?.count {
            throw BridgeError.invalidCalibration("ROI x/y point counts must match.")
        }
        if let roiX, roiX.count != 2 {
            throw BridgeError.invalidCalibration("ROI x/y must each contain [minimum, maximum].")
        }
        if let roiX, roiX[0] > roiX[1] {
            throw BridgeError.invalidCalibration("ROI minimum must not exceed maximum.")
        }
        if let roiY, roiY[0] > roiY[1] {
            throw BridgeError.invalidCalibration("ROI minimum must not exceed maximum.")
        }
        return AnalysisCalibration(
            startLine: startLine,
            endLine: endLine,
            distanceM: message.distanceM,
            homographyImagePoints: imagePoints,
            homographyWorldPointsM: worldPoints,
            roiX: roiX,
            roiY: roiY
        )
    }

    static func fileSHA256(_ url: URL) async throws -> String {
        let hashTask = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
                    break
                }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await hashTask.value
        } onCancel: {
            hashTask.cancel()
        }
    }

    static func videoDimensions(
        asset: AVURLAsset,
        suppliedWidth: Int,
        suppliedHeight: Int
    ) async throws -> (width: Int, height: Int) {
        if suppliedWidth > 0, suppliedHeight > 0 {
            return (suppliedWidth, suppliedHeight)
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw BridgeError.invalidVideo("Input has no video track: \(asset.url.path)")
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized.size
        let width = Int(oriented.width.rounded())
        let height = Int(oriented.height.rounded())
        guard width > 0, height > 0 else {
            throw BridgeError.invalidVideo("Could not determine video dimensions: \(asset.url.path)")
        }
        return (width, height)
    }

    static func message(_ event: AnalysisEvent) -> RunnerAnalysisEventMessage {
        RunnerAnalysisEventMessage(
            stage: stage(event.stage),
            status: status(event.status),
            sequence: Int64(event.sequence),
            progress: event.progress.map {
                guard $0.total > 0 else { return 0 }
                return min(1, max(0, $0.completed / $0.total))
            },
            message: event.message,
            bundlePath: event.stage == .completed ? event.message : nil,
            failure: event.error.map {
                RunnerAnalysisFailureMessage(
                    code: $0.code,
                    message: $0.message,
                    retriable: $0.retriable
                )
            }
        )
    }

    static func stage(_ value: AnalysisStage) -> RunnerAnalysisStageMessage {
        switch value {
        case .validating: return .validating
        case .prescan: return .prescan
        case .tracking: return .tracking
        case .pose2d: return .pose2d
        case .pose3d: return .pose3d
        case .speed: return .speed
        case .gait: return .gait
        case .export: return .export
        case .sync: return .sync
        case .completed: return .completed
        case .failed: return .failed
        }
    }

    static func status(_ value: AnalysisEventStatus) -> RunnerAnalysisEventStatusMessage {
        switch value {
        case .started: return .started
        case .progress: return .progress
        case .completed: return .completed
        case .skipped: return .skipped
        case .failed: return .failed
        }
    }
}
