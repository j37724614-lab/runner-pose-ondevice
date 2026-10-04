import AVFoundation
import CryptoKit
import Foundation
import RunnerAnalysisKit
import RunnerPoseKit
import CoreML

/// Drives one benchmarking run from the UI. Holds the picked knobs, builds a `Config`,
/// runs `RunnerPoseEngine`, and surfaces progress + the final `BenchReport`.
@MainActor
final class BenchRunner: ObservableObject {

    // ---- knobs (bound to the UI) ----
    @Published var detector: DetectorModel = .yolo26n
    #if targetEnvironment(simulator)
    @Published var computeUnit: ComputeUnitChoice = .cpuOnly
    #else
    @Published var computeUnit: ComputeUnitChoice = .cpuAndNeuralEngine
    #endif
    @Published var detectorCadence: Int = 1
    @Published var maxInFlight: Int = 3
    @Published var warmupRuns: Int = 3
    @Published var implementationVariant: String = "naive"

    // ---- run state ----
    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentFrame = 0
    @Published private(set) var liveFPS: Double = 0
    @Published private(set) var statusText = "Idle"
    @Published private(set) var isRunningDummyInput = false
    @Published private(set) var dummyInputText: String?
    @Published private(set) var lastReport: BenchReport?
    @Published private(set) var exportedVideoURL: URL?
    @Published private(set) var isExportingVideo = false
    @Published private(set) var exportProgress: Double = 0
    @Published private(set) var exportStatusText = "No export"
    @Published private(set) var prescanVideoURL: URL?
    @Published private(set) var isExportingPrescanVideo = false
    @Published private(set) var prescanExportProgress: Double = 0
    @Published private(set) var prescanExportStatusText = "No prescan export"
    @Published private(set) var errorText: String?
    @Published private(set) var localBundleURL: URL?

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
    private var localAnalysisEngine: RunnerAnalysisEngine?
    private var task: Task<Void, Never>?
    private var lastVideoURL: URL?
    private var lastPoses: [RunnerPose] = []

    func config() -> Config {
        var c = Config()
        c.detectorModel = detector
        c.computeUnits = computeUnit.mlValue
        c.detectorCadence = detectorCadence
        c.maxInFlight = maxInFlight
        c.progressHandler = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if event.totalFrames > 0 {
                    self.progress = min(1, Double(event.currentFrame) / Double(event.totalFrames))
                }
                self.currentFrame = event.currentFrame
                self.statusText = event.message.isEmpty ? event.stage.rawValue : event.message
            }
        }
        return c
    }

    func run(video: URL, runIndex: Int) {
        guard !isRunning else { return }
        #if DEBUG
        print("[BenchAppDebug] run begin video=\(video.lastPathComponent) detector=\(detector.rawValue) compute=\(computeUnit.rawValue) cadence=\(detectorCadence)")
        #endif
        isRunning = true
        progress = 0
        currentFrame = 0
        liveFPS = 0
        statusText = "Starting"
        errorText = nil
        exportedVideoURL = nil
        exportProgress = 0
        exportStatusText = "No export"
        prescanVideoURL = nil
        prescanExportProgress = 0
        prescanExportStatusText = "No prescan export"
        lastVideoURL = video
        lastPoses = []
        localBundleURL = nil

        task = Task {
            let started = Date()
            var seenFrames = 0
            do {
                let engine: RunnerPoseEngine
                if let existing = self.engine {
                    #if DEBUG
                    print("[BenchAppDebug] reconfigure existing engine")
                    #endif
                    try await existing.reconfigure(self.config())
                    engine = existing
                } else {
                    #if DEBUG
                    print("[BenchAppDebug] create RunnerPoseEngine")
                    #endif
                    engine = try await RunnerPoseEngine(config: self.config())
                    self.engine = engine
                }
                #if DEBUG
                print("[BenchAppDebug] warmUp begin")
                #endif
                await engine.warmUp()
                #if DEBUG
                print("[BenchAppDebug] warmUp end")
                #endif

                let cond = RunnerPoseEngine.baseConditions(
                    videoName: video.lastPathComponent,
                    implementationVariant: self.implementationVariant,
                    runIndex: runIndex,
                    warmupRuns: self.warmupRuns
                )
                let totalFrames = (try? await Self.frameCount(of: video)) ?? 0
                #if DEBUG
                print("[BenchAppDebug] totalFrames=\(totalFrames)")
                #endif

                let stream = engine.poses(for: video, conditions: cond)
                for try await pose in stream {
                    seenFrames += 1
                    let elapsed = Date().timeIntervalSince(started)
                    await MainActor.run {
                        self.lastPoses.append(pose)
                        self.currentFrame = pose.frameIndex
                        self.statusText = pose.valid ? "Processing pose frame \(pose.frameIndex)" : "Gate skipped frame \(pose.frameIndex)"
                        self.liveFPS = elapsed > 0 ? Double(seenFrames) / elapsed : 0
                        if totalFrames > 0 {
                            self.progress = min(1, Double(pose.frameIndex) / Double(totalFrames))
                        }
                    }
                }

                let report = await engine.lastRun()
                #if DEBUG
                print("[BenchAppDebug] run finished report=\(String(describing: report?.id))")
                #endif
                await MainActor.run {
                    self.lastReport = report
                    self.history = BenchResultStore.shared.reports
                    self.progress = 1
                    self.statusText = "Finished"
                    self.isRunning = false
                }
            } catch {
                #if DEBUG
                print("[BenchAppDebug] run failed error=\(error)")
                #endif
                await MainActor.run {
                    self.errorText = "\(error)"
                    self.statusText = "Failed"
                    self.isRunning = false
                }
            }
        }
    }

    /// Step 7 device gate: run the same S0-S5 implementation through the new
    /// high-level interface and publish a minimal Local result bundle.
    func runLocalAnalysis(video: URL) {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        currentFrame = 0
        liveFPS = 0
        statusText = "Preparing Local request"
        errorText = nil
        localBundleURL = nil

        task = Task {
            do {
                let metadata = try await Self.metadata(for: video)
                let videoHash = try await Task.detached {
                    try Self.sha256(of: video)
                }.value
                let request = AnalysisRequest(
                    analysisKind: .running,
                    cameras: [
                        AnalysisCamera(
                            cameraIndex: 0,
                            video: AnalysisVideo(
                                uri: video.path,
                                sha256: videoHash,
                                fps: metadata.fps,
                                width: metadata.width,
                                height: metadata.height,
                                frameCount: metadata.frameCount,
                                // AVAssetReader emits buffers in natural pixel orientation.
                                rotationDegrees: 0
                            )
                        ),
                    ]
                )
                let outputRoot = try Self.localResultRoot()
                let analysisEngine = RunnerAnalysisEngine(
                    pose2D: RunnerPose2DAdapter(config: self.config()),
                    storage: LocalAnalysisResultStore(rootURL: outputRoot)
                )
                self.localAnalysisEngine = analysisEngine

                let stream = await analysisEngine.analyze(request)
                for await event in stream {
                    self.statusText = event.message ?? "Local: \(event.stage.rawValue) \(event.status.rawValue)"
                    self.progress = Self.progress(for: event.stage, status: event.status)
                    if event.stage == .failed {
                        self.errorText = event.error?.message ?? "Local analysis failed"
                    } else if event.stage == .completed, let path = event.message {
                        self.localBundleURL = URL(fileURLWithPath: path)
                    }
                }
                self.isRunning = false
                self.localAnalysisEngine = nil
            } catch {
                self.errorText = String(describing: error)
                self.statusText = "Local analysis failed"
                self.isRunning = false
                self.localAnalysisEngine = nil
            }
        }
    }

    func cancel() {
        task?.cancel()
        if let localAnalysisEngine {
            Task { await localAnalysisEngine.cancel() }
        }
        isRunning = false
        statusText = "Cancelled"
    }

    func runDummyInputTest() {
        guard !isRunningDummyInput else { return }
        isRunningDummyInput = true
        dummyInputText = "Running dummy input..."

        let config = self.config()
        Task {
            let lines = await RunnerPoseDiagnostics.runDummyInput(config: config)
            await MainActor.run {
                self.dummyInputText = lines.joined(separator: "\n")
                self.isRunningDummyInput = false
            }
        }
    }

    func exportOverlayVideo() {
        guard !isExportingVideo, let video = lastVideoURL, !lastPoses.isEmpty else { return }
        isExportingVideo = true
        exportProgress = 0
        exportStatusText = "Starting HRNet export"
        exportedVideoURL = nil
        errorText = nil

        let poses = lastPoses
        Task {
            do {
                let url = try await RunnerPoseVideoExporter.exportOverlayVideo(
                    sourceURL: video,
                    poses: poses
                ) { [weak self] progress, message in
                    Task { @MainActor [weak self] in
                        self?.exportProgress = progress
                        self?.exportStatusText = message
                    }
                }
                await MainActor.run {
                    self.exportedVideoURL = url
                    self.exportProgress = 1
                    self.exportStatusText = "Export complete"
                    self.isExportingVideo = false
                }
            } catch {
                await MainActor.run {
                    self.errorText = "\(error)"
                    self.exportStatusText = "Export failed"
                    self.isExportingVideo = false
                }
            }
        }
    }

    func exportPrescanOverlayVideo(sourceURL: URL) {
        guard !isExportingPrescanVideo else { return }
        isExportingPrescanVideo = true
        prescanExportProgress = 0
        prescanExportStatusText = "Starting prescan export"
        prescanVideoURL = nil
        errorText = nil

        let config = self.config()
        Task {
            do {
                let url = try await RunnerPoseVideoExporter.exportPrescanOverlayVideo(
                    sourceURL: sourceURL,
                    config: config
                ) { [weak self] progress, message in
                    Task { @MainActor [weak self] in
                        self?.prescanExportProgress = progress
                        self?.prescanExportStatusText = message
                    }
                }
                await MainActor.run {
                    self.prescanVideoURL = url
                    self.prescanExportProgress = 1
                    self.prescanExportStatusText = "Prescan export complete"
                    self.isExportingPrescanVideo = false
                }
            } catch {
                await MainActor.run {
                    self.errorText = "\(error)"
                    self.prescanExportStatusText = "Prescan export failed"
                    self.isExportingPrescanVideo = false
                }
            }
        }
    }

    private static func frameCount(of url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return 0 }
        let fps = Double(try await track.load(.nominalFrameRate))
        let dur = try await asset.load(.duration)
        return max(0, Int((dur.seconds * fps).rounded()))
    }

    private struct VideoMetadata {
        var fps: Double
        var width: Int
        var height: Int
        var frameCount: Int
    }

    private static func metadata(for url: URL) async throws -> VideoMetadata {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RunnerPoseError.noVideoTrack(url)
        }
        let size = try await track.load(.naturalSize)
        let fps = Double(try await track.load(.nominalFrameRate))
        let assetDuration = try await asset.load(.duration)
        let duration = assetDuration.seconds
        return VideoMetadata(
            fps: fps,
            width: max(1, Int(abs(size.width).rounded())),
            height: max(1, Int(abs(size.height).rounded())),
            frameCount: max(1, Int((duration * fps).rounded()))
        )
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func localResultRoot() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documents.appendingPathComponent("RunnerAnalysisResults", isDirectory: true)
    }

    private static func progress(
        for stage: RunnerAnalysisKit.AnalysisStage,
        status: AnalysisEventStatus
    ) -> Double {
        if stage == .completed { return 1 }
        let base: Double = switch stage {
        case .validating: 0.05
        case .pose2d: 0.15
        case .export: 0.9
        case .failed: 0
        default: 0.1
        }
        return status == .completed ? min(0.99, base + 0.05) : base
    }

    func clearHistory() {
        BenchResultStore.shared.clear()
        history = []
    }
}
