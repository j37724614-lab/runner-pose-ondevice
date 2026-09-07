import Foundation

/// Per-stage wall-clock accumulation (規劃書 §05 / §06). One instance per run.
public struct StageTimer: Sendable {
    public enum Stage: String, CaseIterable, Sendable, Codable {
        case prescan, decode, detect, warp, hrnet, postproc
    }

    private var samples: [Stage: [Double]] = [:]

    public init() {}

    /// Time `body` and file it under `stage`. Returns whatever `body` returns.
    @discardableResult
    public mutating func measure<T>(_ stage: Stage, _ body: () throws -> T) rethrows -> T {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let out = try body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        samples[stage, default: []].append(ms)
        return out
    }

    public mutating func record(_ stage: Stage, ms: Double) {
        samples[stage, default: []].append(ms)
    }

    public func summary(for stage: Stage, warmup: Int = 0) -> StageStats? {
        guard let all = samples[stage], all.count > warmup else { return nil }
        return StageStats(all.suffix(from: warmup).sorted())
    }

    public var stagesSeen: [Stage] { Stage.allCases.filter { samples[$0]?.isEmpty == false } }
}

public struct StageStats: Sendable, Codable {
    public let count: Int
    public let mean, p50, p90, max, min: Double

    init(_ sortedMs: [Double]) {
        count = sortedMs.count
        min = sortedMs.first ?? 0
        max = sortedMs.last ?? 0
        mean = sortedMs.reduce(0, +) / Double(max(count, 1))
        func pct(_ p: Double) -> Double {
            guard !sortedMs.isEmpty else { return 0 }
            let i = Swift.min(sortedMs.count - 1, Int((p * Double(sortedMs.count - 1)).rounded()))
            return sortedMs[i]
        }
        p50 = pct(0.50)
        p90 = pct(0.90)
    }
}
