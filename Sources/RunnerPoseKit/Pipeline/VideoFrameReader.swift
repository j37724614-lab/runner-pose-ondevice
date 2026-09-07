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
                        continuation.yield(DecodedFrame(pixelBuffer: px, frameIndex: idx, timestamp: pts))
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

    private static func frameSet(_ ranges: [PrescanFilter.FrameRange]) -> Set<Int>? {
        guard !ranges.isEmpty else { return nil }
        var s = Set<Int>()
        for r in ranges { for f in r.startFrame...r.endFrame { s.insert(f) } }
        return s
    }
}
