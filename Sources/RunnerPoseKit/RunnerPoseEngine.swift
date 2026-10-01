import AVFoundation
import CoreML
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Public entry point (規劃書 §03 對外 API).
///
/// `actor` → one detector + one HRNet instance, ANE access serialised.
/// `BenchApp` and the `runner_pose` Flutter plugin both consume `poses(for:)`.
public actor RunnerPoseEngine {
    public private(set) var config: Config
    private var detector: PersonDetector
    private var hrnet: HRNetRunner
    private var cropWarp: CropWarp
    private var decoder: HeatmapDecoder
    private var lastReport: BenchReport?

    public init(config: Config = Config()) async throws {
        config.progressHandler?(.init(stage: .initializing, message: "Initializing detector and HRNet"))
        self.config = config
        self.detector = try DetectorFactory.make(config)
        self.hrnet = try HRNetRunner(config: config)
        self.cropWarp = try CropWarp(config: config)
        self.decoder = HeatmapDecoder(config: config)
    }

    /// Rebuild for a new detector / compute unit without recreating the actor.
    /// Used by the BenchApp picker between runs.
    public func reconfigure(_ config: Config) async throws {
        config.progressHandler?(.init(stage: .initializing, message: "Reconfiguring detector and HRNet"))
        self.config = config
        self.detector = try DetectorFactory.make(config)
        self.hrnet = try HRNetRunner(config: config)
        self.cropWarp = try CropWarp(config: config)
        self.decoder = HeatmapDecoder(config: config)
    }

    /// Load weights and JIT the graphs so the first real frame is not an outlier.
    public func warmUp() async {
        config.progressHandler?(.init(stage: .warmingUp, message: "Warming up detector"))
        await detector.warmUp()
        config.progressHandler?(.init(stage: .warmingUp, message: "Warming up HRNet"))
        await hrnet.warmUp()
    }

    /// Stream per-frame poses for `video`. Only frames inside the prescan valid ranges
    /// are emitted (plus `valid == false` markers for gated frames in those ranges).
    ///
    /// `nonisolated` so callers don't need `await` just to get the stream; the actual
    /// pipeline (`runToCompletion`) runs actor-isolated, so the detector / model
    /// instances are never touched concurrently.
    public nonisolated func poses(
        for video: URL,
        conditions: BenchReport.Conditions
    ) -> AsyncThrowingStream<RunnerPose, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runToCompletion(video: video, conditions: conditions) { pose in
                        continuation.yield(pose)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Actor-isolated pipeline run. `onPose` is called for every frame (Sendable closure).
    private func runToCompletion(
        video: URL,
        conditions: BenchReport.Conditions,
        onPose: @Sendable (RunnerPose) -> Void
    ) async throws {
        var conditions = conditions
        conditions.detectorModel = config.detectorModel.rawValue
        conditions.detectorCadence = config.detectorCadence
        conditions.computeUnits = String(describing: config.computeUnits)
        conditions.maxInFlight = config.maxInFlight

        let pipeline = PosePipeline(
            config: config, detector: detector, hrnet: hrnet,
            cropWarp: cropWarp, decoder: decoder
        )
        let out = try await pipeline.run(url: video, conditions: conditions, onPose: onPose)
        lastReport = out.report
        BenchResultStore.shared.append(out.report, perFrame: out.perFrame)
    }

    /// The `BenchReport` from the most recent completed `poses(for:)`.
    public func lastRun() -> BenchReport? { lastReport }

    /// Convenience: run to completion, collect poses, return with the report.
    public func analyze(
        _ video: URL,
        conditions: BenchReport.Conditions
    ) async throws -> (poses: [RunnerPose], report: BenchReport) {
        var poses: [RunnerPose] = []
        for try await p in self.poses(for: video, conditions: conditions) { poses.append(p) }
        guard let report = lastReport else { throw RunnerPoseError.cancelled }
        return (poses, report)
    }

    /// Fill in device / OS / build fields the caller usually can't be bothered with.
    public static func baseConditions(
        videoName: String,
        implementationVariant: String = "naive",
        runIndex: Int = 0,
        warmupRuns: Int = 3
    ) -> BenchReport.Conditions {
        var battery = -1.0
        var deviceModel = "unknown"
        var os = ProcessInfo.processInfo.operatingSystemVersionString
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        battery = Double(UIDevice.current.batteryLevel)
        deviceModel = UIDevice.current.model
        os = UIDevice.current.systemVersion
        #endif
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        return BenchReport.Conditions(
            detectorModel: "", detectorCadence: 0, computeUnits: "", maxInFlight: 0,
            videoName: videoName, videoFrames: 0, videoFPS: 0,
            deviceModel: deviceModel, osVersion: os, appBuild: build,
            startThermalState: ThermalSampler.name(ProcessInfo.processInfo.thermalState),
            startBatteryLevel: battery,
            implementationVariant: implementationVariant,
            runIndex: runIndex, warmupRuns: warmupRuns
        )
    }
}
