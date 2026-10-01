import AVFoundation
import CoreMedia
import CoreVideo

/// S1 — zero-copy frame decode, restricted to the prescan valid ranges.
///
/// `AVAssetReaderTrackOutput` with `alwaysCopiesSampleData = false`, BGRA, IOSurface
/// backed (規劃書 §04 影格路徑). Not `AVPlayer`.
struct DecodedFrame {
    var pixelBuffer: CVPixelBuffer
    var frameIndex: Int
    var timestamp: CMTime
    var frameSize: CGSize
}

struct VideoInfo: Sendable {
    var frameSize: CGSize
    var nominalFPS: Double
    var totalFrames: Int
}

enum VideoFrameReader {

    static func info(for url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RunnerPoseError.noVideoTrack(url)
        }
        let size = try await track.load(.naturalSize)
        let fps = Double(try await track.load(.nominalFrameRate))
        let dur = try await asset.load(.duration)
        return VideoInfo(
            frameSize: size,
            nominalFPS: fps,
            totalFrames: max(0, Int((dur.seconds * fps).rounded()))
        )
    }

    /// Yields frames whose index falls inside one of `ranges`. `ranges` empty -> whole video.
    static func frames(
        url: URL,
        in ranges: [PrescanFilter.FrameRange]
    ) -> AsyncThrowingStream<DecodedFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let asset = AVURLAsset(url: url)
                    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                        throw RunnerPoseError.noVideoTrack(url)
                    }
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(
                        track: track,
                        outputSettings: [
                            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                        ]
                    )
                    output.alwaysCopiesSampleData = false
                    reader.add(output)

                    // Reading the whole track and index-filtering keeps the port close to
                    // the Python loop. Per-range seeking (reader.timeRange) is a P2
                    // refinement when kept_ratio is low. TODO(mac): benchmark both.
                    reader.startReading()

                    let wanted = Self.frameSet(ranges)
                    var idx = 0
                    while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
                        defer { idx += 1 }
                        if let wanted, !wanted.contains(idx) { continue }
                        guard let px = CMSampleBufferGetImageBuffer(sample) else { continue }
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        let frameSize = CGSize(
                            width: CVPixelBufferGetWidth(px),
                            height: CVPixelBufferGetHeight(px)
                        )
                        continuation.yield(DecodedFrame(
                            pixelBuffer: px,
                            frameIndex: idx,
                            timestamp: pts,
                            frameSize: frameSize
                        ))
                        try Task.checkCancellation()
                    }
                    if reader.status == .failed { throw reader.error ?? RunnerPoseError.videoUnreadable(url) }
                    reader.cancelReading()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reads and processes frames sequentially in the caller's task.
    ///
    /// This gives the pipeline strict back-pressure: the next sample is not pulled
    /// until downstream processing has finished with the current `DecodedFrame`.
    static func forEachFrame(
        url: URL,
        in ranges: [PrescanFilter.FrameRange],
        _ body: (DecodedFrame) async throws -> Void
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RunnerPoseError.noVideoTrack(url)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? RunnerPoseError.videoUnreadable(url)
        }
        defer { reader.cancelReading() }

        var rangeIndex = 0
        var idx = 0
        while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
            defer { idx += 1 }
            try Task.checkCancellation()
            if !Self.isFrame(idx, in: ranges, rangeIndex: &rangeIndex) { continue }
            guard let px = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let frameSize = CGSize(
                width: CVPixelBufferGetWidth(px),
                height: CVPixelBufferGetHeight(px)
            )
            try await body(DecodedFrame(
                pixelBuffer: px,
                frameIndex: idx,
                timestamp: pts,
                frameSize: frameSize
            ))
        }
        if reader.status == .failed {
            throw reader.error ?? RunnerPoseError.videoUnreadable(url)
        }
    }

    private static func frameSet(_ ranges: [PrescanFilter.FrameRange]) -> Set<Int>? {
        guard !ranges.isEmpty else { return nil }
        var s = Set<Int>()
        for r in ranges { for f in r.startFrame...r.endFrame { s.insert(f) } }
        return s
    }

    private static func isFrame(
        _ frameIndex: Int,
        in ranges: [PrescanFilter.FrameRange],
        rangeIndex: inout Int
    ) -> Bool {
        guard !ranges.isEmpty else { return true }
        while rangeIndex < ranges.count, frameIndex > ranges[rangeIndex].endFrame {
            rangeIndex += 1
        }
        guard rangeIndex < ranges.count else { return false }
        let range = ranges[rangeIndex]
        return frameIndex >= range.startFrame && frameIndex <= range.endFrame
    }
}
