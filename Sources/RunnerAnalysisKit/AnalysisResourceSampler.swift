import Foundation
import RunnerPoseKit

#if canImport(UIKit)
import UIKit
#endif

public struct AnalysisResourceTrace: Codable, Sendable, Equatable {
    public struct Sample: Codable, Sendable, Equatable {
        public var atSeconds: Double
        public var stage: AnalysisStage
        public var footprintMB: Double
        public var thermalState: String

        enum CodingKeys: String, CodingKey {
            case atSeconds = "at_seconds"
            case stage
            case footprintMB = "footprint_mb"
            case thermalState = "thermal_state"
        }
    }

    public struct MemoryWarning: Codable, Sendable, Equatable {
        public var atSeconds: Double
        public var stage: AnalysisStage
        public var footprintMB: Double?

        enum CodingKeys: String, CodingKey {
            case atSeconds = "at_seconds"
            case stage
            case footprintMB = "footprint_mb"
        }
    }

    public var samplingIntervalSeconds: Double
    public var peakMB: Double
    public var samples: [Sample]
    public var memoryWarnings: [MemoryWarning]

    enum CodingKeys: String, CodingKey {
        case samplingIntervalSeconds = "sampling_interval_seconds"
        case peakMB = "peak_mb"
        case samples
        case memoryWarnings = "memory_warnings"
    }
}

/// Samples the whole Local analysis lifecycle, including model setup, 2D, 3D,
/// kinematics and result export. The trace is copied into the result bundle by
/// `LocalAnalysisResultStore` immediately before the manifest is sealed.
public final class AnalysisResourceSampler: @unchecked Sendable {
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "runneranalysis.resource-sampler")
    private var timer: DispatchSourceTimer?
    private var startedAtUptime: TimeInterval = 0
    private var currentStage: AnalysisStage = .validating
    private var samples: [AnalysisResourceTrace.Sample] = []
    private var memoryWarnings: [AnalysisResourceTrace.MemoryWarning] = []
    private var memoryWarningObserver: NSObjectProtocol?
    private var isRunning = false

    public init(interval: TimeInterval = 0.25) {
        self.interval = interval
    }

    public func start(stage: AnalysisStage = .validating) {
        stop()
        queue.sync {
            startedAtUptime = ProcessInfo.processInfo.systemUptime
            currentStage = stage
            samples = []
            memoryWarnings = []
            isRunning = true
        }

        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.recordMemoryWarning()
        }
        #endif

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval)
        source.setEventHandler { [weak self] in self?.recordSampleLocked() }
        source.resume()
        queue.sync { timer = source }
    }

    public func setStage(_ stage: AnalysisStage) {
        queue.sync {
            guard isRunning else { return }
            currentStage = stage
            recordSampleLocked()
        }
    }

    public func stop() {
        queue.sync {
            guard isRunning || timer != nil else { return }
            if isRunning { recordSampleLocked() }
            timer?.cancel()
            timer = nil
            isRunning = false
        }
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
        memoryWarningObserver = nil
    }

    public func trace() -> AnalysisResourceTrace {
        queue.sync {
            let values = samples
            return AnalysisResourceTrace(
                samplingIntervalSeconds: interval,
                peakMB: values.map(\.footprintMB).max() ?? 0,
                samples: values,
                memoryWarnings: memoryWarnings
            )
        }
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(trace())
    }

    private func recordMemoryWarning() {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.memoryWarnings.append(.init(
                atSeconds: self.elapsedSecondsLocked(),
                stage: self.currentStage,
                footprintMB: MemorySampler.footprintMB()
            ))
        }
    }

    private func recordSampleLocked() {
        guard isRunning, let footprint = MemorySampler.footprintMB() else { return }
        samples.append(.init(
            atSeconds: elapsedSecondsLocked(),
            stage: currentStage,
            footprintMB: footprint,
            thermalState: ThermalSampler.name(ProcessInfo.processInfo.thermalState)
        ))
    }

    private func elapsedSecondsLocked() -> Double {
        ProcessInfo.processInfo.systemUptime - startedAtUptime
    }
}
