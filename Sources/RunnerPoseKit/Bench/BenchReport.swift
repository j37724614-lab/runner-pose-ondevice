import Foundation

/// One run's full result. The single output for measurement data (規劃書 §03 / §06).
/// `conditions` records every knob so runs can be compared afterwards (規劃書 §06 lede).
public struct BenchReport: Codable, Sendable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var conditions: Conditions
    public var totals: Totals
    public var stages: [String: StageStats]
    public var memory: Memory
    public var thermal: [ThermalSampler.Transition]
    /// Optional path/URL to the per-frame CSV written alongside.
    public var perFrameCSVName: String?

    public struct Conditions: Codable, Sendable {
        public var detectorModel: String
        public var detectorCadence: Int
        public var computeUnits: String
        public var maxInFlight: Int
        public var videoName: String
        public var videoFrames: Int
        public var videoFPS: Double
        public var deviceModel: String
        public var osVersion: String
        public var appBuild: String          // "release" / "debug"
        public var startThermalState: String
        public var startBatteryLevel: Double // -1 if unknown
        public var implementationVariant: String // "naive" / "optimized" / custom
        public var runIndex: Int
        public var warmupRuns: Int
    }

    public struct Totals: Codable, Sendable {
        public var wallClockSeconds: Double
        public var framesProcessed: Int
        public var framesSkippedByGate: Int
        public var validRangeFrames: Int
        public var totalVideoFrames: Int
        public var effectiveFPS: Double
        public var modelLoadSeconds: Double
        public var prescanSeconds: Double
        public var prescanKeptRatio: Double
        public var detectionFrames: Int      // fresh YOLO runs
        public var extrapolatedFrames: Int
    }

    public struct Memory: Codable, Sendable {
        public var peakMB: Double
        public var samplesMB: [Double]
        public var receivedMemoryWarning: Bool
    }

    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }
}

/// Per-frame rows — always written so distributions can be recomputed (規劃書 §05 P2).
public struct PerFrameRow: Sendable {
    public var frameIndex: Int
    public var timeSeconds: Double
    public var valid: Bool
    public var bboxExtrapolated: Bool
    public var decodeMs: Double
    public var detectMs: Double
    public var warpMs: Double
    public var hrnetMs: Double
    public var postprocMs: Double
    public var thermalState: String
    public var footprintMB: Double

    public static let csvHeader =
        "frame,time_s,valid,bbox_extrapolated,decode_ms,detect_ms,warp_ms,hrnet_ms,postproc_ms,thermal,footprint_mb"

    public var csvLine: String {
        "\(frameIndex),\(timeSeconds),\(valid ? 1 : 0),\(bboxExtrapolated ? 1 : 0),"
        + "\(decodeMs),\(detectMs),\(warpMs),\(hrnetMs),\(postprocMs),\(thermalState),\(footprintMB)"
    }
}
