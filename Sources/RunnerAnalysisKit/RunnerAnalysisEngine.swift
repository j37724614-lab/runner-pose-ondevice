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

public protocol AnalysisResultStoring: Sendable {
    func finalize(
        manifest: AnalysisResultManifest,
        pose2D: Analysis2DResult
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
    private let storage: any AnalysisResultStoring
    private let clock: any AnalysisClock
    private var activeTask: Task<Void, Never>?
    private var activeRunID: UUID?

    public init(
        pose2D: any Analysis2DProcessing,
        storage: any AnalysisResultStoring,
        clock: any AnalysisClock = SystemAnalysisClock()
    ) {
        self.pose2D = pose2D
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
            stages.append(.init(
                name: .pose2d,
                status: .completed,
                durationSeconds: result2D.durationSeconds
            ))

            continuation.yield(event(.export, .started))
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
                summary: AnalysisSummary(totalTimeSeconds: result2D.durationSeconds),
                warnings: ["Only the Step 7 single-camera 2D stage is available in this bundle."]
            )
            let storedResult: StoredAnalysisResult
            do {
                storedResult = try await storage.finalize(manifest: manifest, pose2D: result2D)
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
