import CryptoKit
import Foundation

public enum RunnerAnalysisError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case cancelled
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
    case processingFailed(String)
    case storageFailed(String)

    var failure: AnalysisFailure {
        switch self {
        case .invalidRequest(let message):
            return AnalysisFailure(code: "invalid_request", message: message, retriable: false)
        case .cancelled:
            return AnalysisFailure(code: "cancelled", message: "Analysis was cancelled.", retriable: true)
        case .insufficientStorage(let required, let available):
            return AnalysisFailure(
                code: "insufficient_storage",
                message: "Local analysis needs \(required) bytes but only \(available) bytes are available.",
                retriable: true
            )
        case .processingFailed(let message):
            return AnalysisFailure(code: "processing_failed", message: message, retriable: true)
        case .storageFailed(let message):
            return AnalysisFailure(code: "storage_failed", message: message, retriable: true)
        }
    }
}

/// Step 7 supplies the adapter backed by RunnerPoseEngine. Step 6 deliberately
/// keeps this boundary small so engine lifecycle tests need no Core ML model.
public protocol Analysis2DProcessing: Sendable {
    func process(request: AnalysisRequest) async throws -> Analysis2DResult
}

public protocol AnalysisKinematicsProcessing: Sendable {
    func process(
        pose2D: Analysis2DResult,
        request: AnalysisRequest
    ) throws -> AnalysisKinematicsResult
}

public protocol AnalysisResultStoring: Sendable {
    func finalize(
        manifest: AnalysisResultManifest,
        pose2D: Analysis2DResult,
        pose3D: Analysis3DResult?,
        kinematics: AnalysisKinematicsResult?,
        resourceSampler: AnalysisResourceSampler?
    ) async throws -> StoredAnalysisResult
}

public protocol AnalysisClock: Sendable {
    func now() -> Date
}

public struct SystemAnalysisClock: AnalysisClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// High-level Local analysis entry point. Flutter consumes this event stream;
/// individual pipeline stages remain private implementation details.
public actor RunnerAnalysisEngine {
    private let pose2D: any Analysis2DProcessing
    private let pose3D: (any Analysis3DProcessing)?
    private let kinematics: any AnalysisKinematicsProcessing
    private let storage: any AnalysisResultStoring
    private let clock: any AnalysisClock
    private var activeTask: Task<Void, Never>?
    private var activeRunID: UUID?

    public init(
        pose2D: any Analysis2DProcessing,
        pose3D: (any Analysis3DProcessing)? = nil,
        kinematics: any AnalysisKinematicsProcessing = ServerAlignedKinematicsProcessor(),
        storage: any AnalysisResultStoring,
        clock: any AnalysisClock = SystemAnalysisClock()
    ) {
        self.pose2D = pose2D
        self.pose3D = pose3D
        self.kinematics = kinematics
        self.storage = storage
        self.clock = clock
    }

    public func analyze(
        _ request: AnalysisRequest,
        comparisonGroupID: UUID? = nil
    ) -> AsyncStream<AnalysisEvent> {
        activeTask?.cancel()
        let runID = UUID()
        activeRunID = runID
        let (stream, continuation) = AsyncStream.makeStream(of: AnalysisEvent.self)
        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.run(
                request,
                runID: runID,
                comparisonGroupID: comparisonGroupID,
                continuation: continuation
            )
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.cancel(runID: runID) }
        }
        return stream
    }

    public func cancel() {
        activeTask?.cancel()
    }

    private func cancel(runID: UUID) {
        guard activeRunID == runID else { return }
        activeTask?.cancel()
    }

    private func run(
        _ request: AnalysisRequest,
        runID: UUID,
        comparisonGroupID: UUID?,
        continuation: AsyncStream<AnalysisEvent>.Continuation
    ) async {
        var sequence = 0
        var stages: [AnalysisStageResult] = []
        let resourceSampler = AnalysisResourceSampler()
        resourceSampler.start(stage: .validating)
        defer { resourceSampler.stop() }

        func event(
            _ stage: AnalysisStage,
            _ status: AnalysisEventStatus,
            message: String? = nil,
            error: AnalysisFailure? = nil
        ) -> AnalysisEvent {
            defer { sequence += 1 }
            return AnalysisEvent(
                requestID: request.requestID,
                runID: runID,
                sequence: sequence,
                timestamp: clock.now(),
                stage: stage,
                status: status,
                message: message,
                error: error
            )
        }

        do {
            continuation.yield(event(.validating, .started))
            try validate(request)
            try Task.checkCancellation()
            continuation.yield(event(.validating, .completed))
            stages.append(.init(name: .validating, status: .completed))

            resourceSampler.setStage(.pose2d)
            continuation.yield(event(.pose2d, .started))
            let result2D: Analysis2DResult
            do {
                result2D = try await pose2D.process(request: request)
            } catch is CancellationError {
                throw RunnerAnalysisError.cancelled
            } catch {
                throw RunnerAnalysisError.processingFailed(String(describing: error))
            }
            try Task.checkCancellation()
            continuation.yield(event(.pose2d, .completed))
            defer {
                if let overlayURL = result2D.overlayVideoURL {
                    try? FileManager.default.removeItem(at: overlayURL)
                }
            }
            stages.append(.init(
                name: .pose2d,
                status: .completed,
                durationSeconds: result2D.durationSeconds
            ))

            let result3D: Analysis3DResult?
            if let pose3D {
                resourceSampler.setStage(.pose3d)
                continuation.yield(event(.pose3d, .started))
                do {
                    result3D = try await pose3D.process(pose2D: result2D, request: request)
                } catch is CancellationError {
                    throw RunnerAnalysisError.cancelled
                } catch let error as RunnerAnalysisError {
                    throw error
                } catch {
                    throw RunnerAnalysisError.processingFailed(String(describing: error))
                }
                try Task.checkCancellation()
                continuation.yield(event(.pose3d, .completed))
                stages.append(.init(
                    name: .pose3d,
                    status: .completed,
                    durationSeconds: result3D?.durationSeconds,
                    warnings: result3D?.warnings.isEmpty == false ? result3D?.warnings : nil
                ))
            } else {
                result3D = nil
                let warning = "MotionAGFormerLarge243 is not bundled; 3D and angles were skipped."
                continuation.yield(event(.pose3d, .skipped, message: warning))
                stages.append(.init(name: .pose3d, status: .skipped, warnings: [warning]))
            }

            resourceSampler.setStage(.speed)
            continuation.yield(event(.speed, .started))
            let kinematicsResult: AnalysisKinematicsResult
            do {
                kinematicsResult = try kinematics.process(pose2D: result2D, request: request)
            } catch let error as RunnerAnalysisError {
                throw error
            } catch {
                throw RunnerAnalysisError.processingFailed(String(describing: error))
            }
            try Task.checkCancellation()
            let storedKinematics: AnalysisKinematicsResult?
            if kinematicsResult.frames.isEmpty {
                storedKinematics = nil
                let warning = kinematicsResult.warnings.first
                    ?? "Distance, speed and acceleration need valid camera calibration."
                continuation.yield(event(.speed, .skipped, message: warning))
                stages.append(.init(name: .speed, status: .skipped, warnings: [warning]))
            } else {
                storedKinematics = kinematicsResult
                continuation.yield(event(.speed, .completed))
                stages.append(.init(
                    name: .speed,
                    status: .completed,
                    durationSeconds: kinematicsResult.durationSeconds,
                    warnings: kinematicsResult.warnings.isEmpty ? nil : kinematicsResult.warnings
                ))
            }

            resourceSampler.setStage(.export)
            continuation.yield(event(.export, .started))
            let totalTime = result2D.durationSeconds
                + (result3D?.durationSeconds ?? 0)
                + (storedKinematics?.durationSeconds ?? 0)
            var warnings = (result3D?.warnings ?? []) + kinematicsResult.warnings
            if result3D == nil {
                warnings.append("MotionAGFormer 3D and angles are unavailable because the model is not bundled.")
            }
            if storedKinematics == nil {
                warnings.append("Distance, speed and acceleration were skipped because calibrated distance was unavailable.")
            }
            warnings.append("Leg identity, contact events and gait metrics remain pending Step 18.")
            if request.cameras.count > 1 && request.outputPolicy.includeOverlays {
                warnings.append("Per-camera overlays are deferred to Step 19.")
            }
            let manifest = AnalysisResultManifest(
                requestID: request.requestID,
                runID: runID,
                comparisonGroupID: comparisonGroupID,
                createdAt: clock.now(),
                configSha256: try configurationHash(request),
                inputVideos: request.cameras.map {
                    AnalysisInputVideoDescriptor(cameraIndex: $0.cameraIndex, sha256: $0.video.sha256)
                },
                stages: stages + [.init(name: .export, status: .completed)],
                summary: AnalysisSummary(
                    totalTimeSeconds: totalTime,
                    averageSpeedMPS: storedKinematics?.averageSpeedMPS,
                    averageAccelerationMPS2: storedKinematics?.averageAccelerationMPS2,
                    maximumSpeedMPS: storedKinematics?.maximumSpeedMPS
                ),
                engine: AnalysisEngineDescriptor(
                    name: "RunnerAnalysisKit",
                    version: "0.1.0-shell",
                    models: result2D.models + (result3D?.models ?? [])
                ),
                warnings: warnings
            )
            let storedResult: StoredAnalysisResult
            do {
                storedResult = try await storage.finalize(
                    manifest: manifest,
                    pose2D: result2D,
                    pose3D: result3D,
                    kinematics: storedKinematics,
                    resourceSampler: resourceSampler
                )
            } catch is CancellationError {
                throw RunnerAnalysisError.cancelled
            } catch let error as RunnerAnalysisError {
                throw error
            } catch {
                throw RunnerAnalysisError.storageFailed(String(describing: error))
            }
            try Task.checkCancellation()
            continuation.yield(event(.export, .completed))
            continuation.yield(event(.completed, .completed, message: storedResult.bundleURL.path))
        } catch is CancellationError {
            continuation.yield(event(.failed, .failed, error: RunnerAnalysisError.cancelled.failure))
        } catch let error as RunnerAnalysisError {
            continuation.yield(event(.failed, .failed, error: error.failure))
        } catch {
            let wrapped = RunnerAnalysisError.processingFailed(String(describing: error))
            continuation.yield(event(.failed, .failed, error: wrapped.failure))
        }
        continuation.finish()
        if activeRunID == runID {
            activeTask = nil
            activeRunID = nil
        }
    }

    private func validate(_ request: AnalysisRequest) throws {
        guard request.schemaVersion == AnalysisContract.schemaVersion else {
            throw RunnerAnalysisError.invalidRequest("Unsupported schema version: \(request.schemaVersion)")
        }
        guard request.computeTargets.contains(.local) else {
            throw RunnerAnalysisError.invalidRequest("Local engine requires compute_targets to contain local.")
        }
        guard !request.cameras.isEmpty else {
            throw RunnerAnalysisError.invalidRequest("At least one camera is required.")
        }
        let indices = request.cameras.map(\.cameraIndex)
        guard Set(indices).count == indices.count else {
            throw RunnerAnalysisError.invalidRequest("camera_index values must be unique.")
        }
        guard indices == Array(0..<indices.count) else {
            throw RunnerAnalysisError.invalidRequest(
                "camera_index values must be sorted, contiguous, and start at zero."
            )
        }
        guard request.cameras.allSatisfy({
            $0.video.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
        }) else {
            throw RunnerAnalysisError.invalidRequest("Every input video needs a lowercase SHA-256 hash.")
        }
    }

    private func configurationHash(_ request: AnalysisRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(request))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
