import Foundation
import XCTest
@testable import RunnerAnalysisKit

final class RunnerAnalysisEngineTests: XCTestCase {
    func testSuccessEventOrderAndDiagnosticManifest() async throws {
        let store = MemoryStore()
        let engine = RunnerAnalysisEngine(
            pose2D: ImmediateProcessor(),
            storage: store,
            clock: FixedClock()
        )

        let events = await collect(await engine.analyze(makeRequest()))

        XCTAssertEqual(events.map(\.stage), [
            .validating, .validating, .pose2d, .pose2d, .export, .export, .completed,
        ])
        XCTAssertEqual(events.map(\.sequence), Array(0..<7))
        XCTAssertEqual(events.last?.status, .completed)
        let manifest = await store.manifest
        XCTAssertEqual(manifest?.computeLocation, .local)
        XCTAssertEqual(manifest?.status, .degraded)
        XCTAssertEqual(manifest?.stages.map(\.name), [.validating, .pose2d, .export])
    }

    func testInvalidRequestHasStableFailureSequence() async {
        let engine = RunnerAnalysisEngine(
            pose2D: ImmediateProcessor(),
            storage: MemoryStore(),
            clock: FixedClock()
        )
        var request = makeRequest()
        request.cameras = []

        let events = await collect(await engine.analyze(request))

        XCTAssertEqual(events.map(\.stage), [.validating, .failed])
        XCTAssertEqual(events.map(\.sequence), [0, 1])
        XCTAssertEqual(events.last?.error?.code, "invalid_request")
    }

    func testProcessorFailureHasStableFailureSequence() async {
        let engine = RunnerAnalysisEngine(
            pose2D: FailingProcessor(),
            storage: MemoryStore(),
            clock: FixedClock()
        )

        let events = await collect(await engine.analyze(makeRequest()))

        XCTAssertEqual(events.map(\.stage), [.validating, .validating, .pose2d, .failed])
        XCTAssertEqual(events.map(\.sequence), [0, 1, 2, 3])
        XCTAssertEqual(events.last?.error?.code, "processing_failed")
    }

    func testCancelFinishesWithTypedCancelledFailure() async {
        let processor = SuspendedProcessor()
        let engine = RunnerAnalysisEngine(
            pose2D: processor,
            storage: MemoryStore(),
            clock: FixedClock()
        )
        let stream = await engine.analyze(makeRequest())
        let collector = Task { await collect(stream) }
        await processor.waitUntilStarted()

        await engine.cancel()
        let events = await collector.value

        XCTAssertEqual(events.last?.stage, .failed)
        XCTAssertEqual(events.last?.status, .failed)
        XCTAssertEqual(events.last?.error?.code, "cancelled")
    }
}

private func makeRequest() -> AnalysisRequest {
    AnalysisRequest(
        requestID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        analysisKind: .running,
        cameras: [
            AnalysisCamera(
                cameraIndex: 0,
                video: AnalysisVideo(
                    uri: "/tmp/input.mov",
                    sha256: String(repeating: "a", count: 64),
                    fps: 60,
                    width: 1920,
                    height: 1080,
                    frameCount: 120,
                    rotationDegrees: 0
                )
            ),
        ]
    )
}

private func collect(_ stream: AsyncStream<AnalysisEvent>) async -> [AnalysisEvent] {
    var result: [AnalysisEvent] = []
    for await event in stream { result.append(event) }
    return result
}

private struct ImmediateProcessor: Analysis2DProcessing {
    func process(request: AnalysisRequest) async throws -> Analysis2DResult {
        Analysis2DResult(frames: [], durationSeconds: 0)
    }
}

private struct FailingProcessor: Analysis2DProcessing {
    struct ExpectedFailure: Error {}
    func process(request: AnalysisRequest) async throws -> Analysis2DResult {
        throw ExpectedFailure()
    }
}

private actor SuspendedProcessor: Analysis2DProcessing {
    private var started = false

    func process(request: AnalysisRequest) async throws -> Analysis2DResult {
        started = true
        while !Task.isCancelled { await Task.yield() }
        throw CancellationError()
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}

private actor MemoryStore: AnalysisResultStoring {
    private(set) var manifest: AnalysisResultManifest?

    func finalize(
        manifest: AnalysisResultManifest,
        pose2D: Analysis2DResult
    ) async throws -> StoredAnalysisResult {
        self.manifest = manifest
        return StoredAnalysisResult(
            bundleURL: URL(fileURLWithPath: "/tmp/analysis-result"),
            manifest: manifest
        )
    }
}

private struct FixedClock: AnalysisClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
}
