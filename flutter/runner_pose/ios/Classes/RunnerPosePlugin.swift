import AVFoundation
import CryptoKit
import Flutter
import Foundation
import RunnerAnalysisKit
import UIKit

public final class RunnerPosePlugin: NSObject, FlutterPlugin, RunnerAnalysisHostApi {
    private let flutterAPI: RunnerAnalysisFlutterApi
    private var analysisEngine: RunnerAnalysisEngine?
    private var analysisTask: Task<Void, Never>?
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
                let engine = RunnerAnalysisEngine(
                    pose2D: RunnerPose2DAdapter(),
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

    private func send(_ event: RunnerAnalysisEventMessage) async {
        await withCheckedContinuation { continuation in
            flutterAPI.onEvent(event: event) { _ in continuation.resume() }
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
        case invalidVideo(String)

        var errorDescription: String? {
            switch self {
            case .analysisAlreadyRunning:
                return "A local analysis is already running."
            case .invalidRequestID(let value):
                return "requestId is not a UUID: \(value)"
            case .invalidComparisonGroupID(let value):
                return "comparisonGroupId is not a UUID: \(value)"
            case .invalidVideo(let message):
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
                )
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

        return MappedRequest(
            request: AnalysisRequest(
                schemaVersion: message.schemaVersion,
                requestID: requestID,
                analysisKind: .running,
                cameras: cameras
            ),
            comparisonGroupID: comparisonGroupID,
            outputDirectory: outputDirectory
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
