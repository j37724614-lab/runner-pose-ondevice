import AVFoundation
import CoreMedia
import Foundation

/// S0 — cheap pre-pass that finds the frame ranges where a qualifying runner is on
/// screen, so S1–S5 skip the empty stretches entirely (規劃書 §03 / §04).
///
/// Faithful port of `scripts/tracking/prescan_filter_valid_video.py`
/// (`_scan_valid_ranges` + `_merge_hit_frames`). Parity gate: `PrescanParityTests`
/// against `testdata/prescan_reference/<scale>/` (規劃書 §05 P1).
///
/// Unlike the desktop tool this writes **no clipped video** — it returns
/// `[FrameRange]` / `[CMTimeRange]` and the reader seeks within them.
struct PrescanFilter {
    let config: Config
    let detector: PersonDetector

    struct FrameRange: Equatable {
        var startFrame: Int
        var endFrame: Int
        var numFrames: Int { endFrame - startFrame + 1 }
    }

    struct Result {
        var ranges: [FrameRange]
        var sampledCount: Int
        var hitCount: Int
        var totalFrames: Int
        var elapsed: TimeInterval
        var keptRatio: Double {
            totalFrames > 0
                ? Double(ranges.reduce(0) { $0 + $1.numFrames }) / Double(totalFrames)
                : 0
        }
    }

    /// Scan the video. Samples every `prescanStride`-th frame through `detector`.
    func scan(url: URL) async throws -> Result {
        DebugLog.mark("Prescan: begin url=\(url.lastPathComponent)")
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            DebugLog.mark("Prescan: no video track")
            throw RunnerPoseError.noVideoTrack(url)
        }
        let fps = Double(try await track.load(.nominalFrameRate))
        let naturalSize = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        let totalFrames = max(0, Int((duration.seconds * fps).rounded()))
        DebugLog.mark(
            "Prescan: metadata fps=\(fps) size=\(Int(naturalSize.width))x\(Int(naturalSize.height)) totalFrames=\(totalFrames)"
        )

        let bufferFrames = Int((config.prescanBufferSec * fps).rounded())
        let maxGapFrames = Int((config.prescanMaxGapSec * fps).rounded())
        config.progressHandler?(.init(
            stage: .prescan,
            currentFrame: 0,
            totalFrames: totalFrames,
            message: "Prescanning video"
        ))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let startedReading = reader.startReading()
        DebugLog.mark("Prescan: reader startReading=\(startedReading) status=\(reader.status.rawValue)")

        let start = Date()
        var frameIdx = 0
        var sampled = 0
        var hitFrames: [Int] = []

        while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
            defer { frameIdx += 1 }
            if frameIdx % config.prescanStride != 0 {
                // cap.grab() equivalent: keep advancing without decoding into a detection.
                continue
            }
            guard let px = CMSampleBufferGetImageBuffer(sample) else { continue }
            let frameSize = CGSize(width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))
            sampled += 1
            if sampled == 1 || sampled % 10 == 0 {
                DebugLog.mark(
                    "Prescan: sampled=\(sampled) frame=\(frameIdx) hits=\(hitFrames.count) bufferSize=\(Int(frameSize.width))x\(Int(frameSize.height))"
                )
                config.progressHandler?(.init(
                    stage: .prescan,
                    currentFrame: frameIdx,
                    totalFrames: totalFrames,
                    message: "Prescan sampled \(sampled), hits \(hitFrames.count)"
                ))
            }
            let dets = try await detector.detect(px, frameSize: frameSize)
            let hit = dets.contains {
                $0.confidence >= config.detectorConf && $0.box.height >= config.minBoxHeight
            }
            if hit { hitFrames.append(frameIdx) }
            if Task.isCancelled { reader.cancelReading(); throw RunnerPoseError.cancelled }
        }
        if reader.status == .failed {
            DebugLog.mark("Prescan: reader failed \(String(describing: reader.error))")
        }
        reader.cancelReading()

        let ranges = Self.mergeHitFrames(
            hitFrames,
            totalFrames: totalFrames,
            stride: config.prescanStride,
            bufferFrames: bufferFrames,
            maxGapFrames: maxGapFrames
        )
        config.progressHandler?(.init(
            stage: .prescan,
            currentFrame: totalFrames,
            totalFrames: totalFrames,
            message: "Prescan complete: \(hitFrames.count) hits"
        ))
        DebugLog.mark(
            "Prescan: end sampled=\(sampled) hits=\(hitFrames.count) ranges=\(ranges.count) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(start)))s"
        )
        return Result(
            ranges: ranges,
            sampledCount: sampled,
            hitCount: hitFrames.count,
            totalFrames: totalFrames,
            elapsed: Date().timeIntervalSince(start)
        )
    }

    /// ```python
    /// def _merge_hit_frames(hit_frames, total_frames, stride, buffer_frames, max_gap_frames):
    ///     if not hit_frames: return []
    ///     ranges = []; start = end = hit_frames[0]
    ///     for f in hit_frames[1:]:
    ///         if f - end <= max_gap_frames: end = f
    ///         else: ranges.append((start, end)); start = end = f
    ///     ranges.append((start, end))
    ///     expanded = []; last_start = last_end = None
    ///     for start, end in ranges:
    ///         start = max(0, start - buffer_frames)
    ///         end = min(max(total_frames - 1, 0), end + buffer_frames + stride - 1)
    ///         if last_start is None: last_start, last_end = start, end
    ///         elif start <= last_end + 1: last_end = max(last_end, end)
    ///         else: expanded.append((last_start, last_end)); last_start, last_end = start, end
    ///     expanded.append((last_start, last_end))
    ///     return expanded
    /// ```
    static func mergeHitFrames(
        _ hitFrames: [Int],
        totalFrames: Int,
        stride: Int,
        bufferFrames: Int,
        maxGapFrames: Int
    ) -> [FrameRange] {
        guard let first = hitFrames.first else { return [] }

        var merged: [(Int, Int)] = []
        var start = first, end = first
        for f in hitFrames.dropFirst() {
            if f - end <= maxGapFrames { end = f }
            else { merged.append((start, end)); start = f; end = f }
        }
        merged.append((start, end))

        var expanded: [(Int, Int)] = []
        var lastStart: Int? = nil
        var lastEnd = 0
        for (s0, e0) in merged {
            let s = max(0, s0 - bufferFrames)
            let e = min(max(totalFrames - 1, 0), e0 + bufferFrames + stride - 1)
            if lastStart == nil {
                lastStart = s; lastEnd = e
            } else if s <= lastEnd + 1 {
                lastEnd = max(lastEnd, e)
            } else {
                expanded.append((lastStart!, lastEnd))
                lastStart = s; lastEnd = e
            }
        }
        if let ls = lastStart { expanded.append((ls, lastEnd)) }

        return expanded.map { FrameRange(startFrame: $0.0, endFrame: $0.1) }
    }
}

extension PrescanFilter.FrameRange {
    /// Half-open time range for AVAssetReader.timeRange.
    func timeRange(fps: Double) -> CMTimeRange {
        let start = CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(fps.rounded()))
        let end = CMTime(value: CMTimeValue(endFrame + 1), timescale: CMTimeScale(fps.rounded()))
        return CMTimeRange(start: start, end: end)
    }
}
