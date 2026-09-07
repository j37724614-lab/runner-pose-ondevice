import AVFoundation
import Foundation
import RunnerPoseKit
import CoreML

/// Drives one benchmarking run from the UI. Holds the picked knobs, builds a `Config`,
/// runs `RunnerPoseEngine`, and surfaces progress + the final `BenchReport`.
@MainActor
final class BenchRunner: ObservableObject {

    // ---- knobs (bound to the UI) ----
    @Published var detector: DetectorModel = .yolo26n
    @Published var computeUnit: ComputeUnitChoice = .cpuAndNeuralEngine
    @Published var detectorCadence: Int = 6
    @Published var maxInFlight: Int = 3
    @Published var warmupRuns: Int = 3
    @Published var implementationVariant: String = "naive"

    // ---- run state ----
    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentFrame = 0
    @Published private(set) var liveFPS: Double = 0
    @Published private(set) var lastReport: BenchReport?
    @Published private(set) var errorText: String?

    @Published private(set) var history: [BenchReport] = BenchResultStore.shared.reports

    enum ComputeUnitChoice: String, CaseIterable, Identifiable {
        case cpuAndNeuralEngine, cpuOnly, cpuAndGPU, all
        var id: String { rawValue }
        var mlValue: MLComputeUnits {
            switch self {
            case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
            case .cpuOnly: return .cpuOnly
            case .cpuAndGPU: return .cpuAndGPU
            case .all: return .all
            }
        }
    }

    private var engine: RunnerPoseEngine?
    private var task: Task<Void, Never>?

    func config() -> Config {
        var c = Config()
        c.detectorModel = detector
        c.computeUnits = computeUnit.mlValue
        c.detectorCadence = detectorCadence
        c.maxInFlight = maxInFlight
        return c
    }

    func run(video: URL, runIndex: Int) {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        currentFrame = 0
        liveFPS = 0
        errorText = nil

        task = Task {
            let started = Date()
            var seenFrames = 0
            do {
                let engine: RunnerPoseEngine
                if let existing = self.engine {
                    try await existing.reconfigure(self.config())
                    engine = existing
                } else {
                    engine = try await RunnerPoseEngine(config: self.config())
                    self.engine = engine
                }
                await engine.warmUp()

                let cond = RunnerPoseEngine.baseConditions(
                    videoName: video.lastPathComponent,
                    implementationVariant: self.implementationVariant,
                    runIndex: runIndex,
                    warmupRuns: self.warmupRuns
                )
                let totalFrames = (try? await Self.frameCount(of: video)) ?? 0

                let stream = await engine.poses(for: video, conditions: cond)
                for try await pose in stream {
                    seenFrames += 1
                    let elapsed = Date().timeIntervalSince(started)
                    await MainActor.run {
                        self.currentFrame = pose.frameIndex
                        self.liveFPS = elapsed > 0 ? Double(seenFrames) / elapsed : 0
                        if totalFrames > 0 {
                            self.progress = min(1, Double(pose.frameIndex) / Double(totalFrames))
                        }
                    }
                }

                let report = await engine.lastRun()
                await MainActor.run {
                    self.lastReport = report
                    self.history = BenchResultStore.shared.reports
                    self.progress = 1
                    self.isRunning = false
                }
            } catch {
                await MainActor.run {
                    self.errorText = "\(error)"
                    self.isRunning = false
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        isRunning = false
    }

    private static func frameCount(of url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return 0 }
        let fps = Double(try await track.load(.nominalFrameRate))
        let dur = try await asset.load(.duration)
        return max(0, Int((dur.seconds * fps).rounded()))
    }

    func clearHistory() {
        BenchResultStore.shared.clear()
        history = []
    }
}
