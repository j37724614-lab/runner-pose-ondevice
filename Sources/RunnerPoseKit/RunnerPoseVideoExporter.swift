import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

public enum RunnerPoseVideoExporter {
    private struct PrescanOverlay {
        var detections: [Detection]
        var picked: Detection?
    }

    private struct PrescanOverlayScan {
        var overlays: [Int: PrescanOverlay]
        var ranges: [PrescanFilter.FrameRange]
    }

    public static func exportOverlayVideo(
        sourceURL: URL,
        poses: [RunnerPose],
        outputURL: URL? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let poseByFrame = Dictionary(uniqueKeysWithValues: poses.map { ($0.frameIndex, $0) })
        // Only write frames that the pipeline actually processed (prescan valid ranges).
        let validFrames = Set(poses.map { $0.frameIndex })
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RunnerPoseError.noVideoTrack(sourceURL)
        }

        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let fps = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration)
        let totalFrames = max(1, Int((duration.seconds * fps).rounded()))
        let destination = try outputURL ?? defaultOutputURL(sourceURL: sourceURL)

        try? FileManager.default.removeItem(at: destination)

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        guard reader.startReading() else {
            throw reader.error ?? RunnerPoseError.videoUnreadable(sourceURL)
        }
        guard let firstSample = readerOutput.copyNextSampleBuffer(),
              let firstBuffer = CMSampleBufferGetImageBuffer(firstSample) else {
            throw RunnerPoseError.videoUnreadable(sourceURL)
        }

        let frameSize = CGSize(
            width: CVPixelBufferGetWidth(firstBuffer),
            height: CVPixelBufferGetHeight(firstBuffer)
        )
        DebugLog.mark(
            "Export: naturalSize=\(Int(naturalSize.width))x\(Int(naturalSize.height)) bufferSize=\(Int(frameSize.width))x\(Int(frameSize.height)) transform=\(preferredTransform)"
        )

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(frameSize.width),
                AVVideoHeightKey: Int(frameSize.height),
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = preferredTransform

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(frameSize.width),
                kCVPixelBufferHeightKey as String: Int(frameSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )

        guard writer.canAdd(writerInput) else {
            throw RunnerPoseError.videoExportFailed("Cannot add AVAssetWriterInput.")
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw writer.error ?? RunnerPoseError.videoExportFailed("Cannot start AVAssetWriter.")
        }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext()
        var frameIndex = 0
        var outputTime = CMTime.zero
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(fps.rounded()))))

        func append(sample: CMSampleBuffer, frameIndex: Int) async throws {
            try Task.checkCancellation()
            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { return }

            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
                try Task.checkCancellation()
            }

            let outputBuffer = try makePixelBuffer(from: adaptor)

            autoreleasepool {
                ciContext.render(CIImage(cvPixelBuffer: sourceBuffer), to: outputBuffer)
                if let pose = poseByFrame[frameIndex] {
                    draw(pose: pose, onto: outputBuffer, frameSize: frameSize)
                }
            }

            if !adaptor.append(outputBuffer, withPresentationTime: outputTime) {
                throw writer.error ?? RunnerPoseError.videoExportFailed("Cannot append frame \(frameIndex).")
            }
            outputTime = CMTimeAdd(outputTime, frameDuration)

            if frameIndex == 0 || frameIndex % 30 == 0 {
                progress?(min(1, Double(frameIndex) / Double(totalFrames)), "Exporting frame \(frameIndex)")
                DebugLog.mark("Export: frame=\(frameIndex) total=\(totalFrames) outputTime=\(String(format: "%.3f", outputTime.seconds))")
            }
        }

        if validFrames.contains(frameIndex) {
            try await append(sample: firstSample, frameIndex: frameIndex)
        }
        frameIndex += 1

        while reader.status == .reading, let sample = readerOutput.copyNextSampleBuffer() {
            if validFrames.contains(frameIndex) {
                try await append(sample: sample, frameIndex: frameIndex)
            }
            frameIndex += 1
        }

        if reader.status == .failed {
            throw reader.error ?? RunnerPoseError.videoUnreadable(sourceURL)
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw writer.error ?? RunnerPoseError.videoExportFailed("AVAssetWriter failed.")
        }

        progress?(1, "Export complete")
        DebugLog.mark("Export: complete path=\(destination.path)")
        return destination
    }

    public static func exportPrescanOverlayVideo(
        sourceURL: URL,
        config: Config,
        outputURL: URL? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RunnerPoseError.noVideoTrack(sourceURL)
        }

        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let fps = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration)
        let totalFrames = max(1, Int((duration.seconds * fps).rounded()))
        let stride = max(1, config.prescanStride)
        let destination = try outputURL ?? defaultOutputURL(sourceURL: sourceURL, suffix: "prescan-yolo-bbox")

        try? FileManager.default.removeItem(at: destination)

        progress?(0, "Loading YOLO")
        DebugLog.mark("Prescan export: load detector begin stride=\(stride)")
        let detector = try DetectorFactory.make(config)
        await detector.warmUp()
        DebugLog.mark("Prescan export: load detector end")

        let scan = try await collectPrescanOverlays(
            asset: asset,
            track: track,
            detector: detector,
            config: config,
            fps: fps,
            totalFrames: totalFrames,
            progress: progress
        )
        guard !scan.ranges.isEmpty else {
            throw RunnerPoseError.videoExportFailed("Prescan found no valid runner ranges.")
        }
        DebugLog.mark(
            "Prescan export: valid ranges=\(scan.ranges.map { "\($0.startFrame)-\($0.endFrame)" }.joined(separator: ","))"
        )

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        guard reader.startReading() else {
            throw reader.error ?? RunnerPoseError.videoUnreadable(sourceURL)
        }
        guard let firstSample = readerOutput.copyNextSampleBuffer(),
              let firstBuffer = CMSampleBufferGetImageBuffer(firstSample) else {
            throw RunnerPoseError.videoUnreadable(sourceURL)
        }

        let frameSize = CGSize(
            width: CVPixelBufferGetWidth(firstBuffer),
            height: CVPixelBufferGetHeight(firstBuffer)
        )
        DebugLog.mark(
            "Prescan export: naturalSize=\(Int(naturalSize.width))x\(Int(naturalSize.height)) bufferSize=\(Int(frameSize.width))x\(Int(frameSize.height)) transform=\(preferredTransform)"
        )

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(frameSize.width),
                AVVideoHeightKey: Int(frameSize.height),
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = preferredTransform

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(frameSize.width),
                kCVPixelBufferHeightKey as String: Int(frameSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )

        guard writer.canAdd(writerInput) else {
            throw RunnerPoseError.videoExportFailed("Cannot add AVAssetWriterInput.")
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw writer.error ?? RunnerPoseError.videoExportFailed("Cannot start AVAssetWriter.")
        }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext()
        var frameIndex = 0
        var outputFrameIndex = 0
        var rangeIndex = 0
        var outputTime = CMTime.zero
        var previousSourceTime: CMTime?
        let fallbackFrameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(fps.rounded()))))

        func append(sample: CMSampleBuffer, frameIndex: Int, frameDuration: CMTime) async throws {
            try Task.checkCancellation()
            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { return }

            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
                try Task.checkCancellation()
            }

            let outputBuffer = try makePixelBuffer(from: adaptor)

            autoreleasepool {
                ciContext.render(CIImage(cvPixelBuffer: sourceBuffer), to: outputBuffer)
                if let overlay = scan.overlays[frameIndex] {
                    drawPrescan(overlay: overlay, onto: outputBuffer, frameSize: frameSize)
                }
            }

            if !adaptor.append(outputBuffer, withPresentationTime: outputTime) {
                throw writer.error ?? RunnerPoseError.videoExportFailed("Cannot append frame \(frameIndex).")
            }
            outputTime = CMTimeAdd(outputTime, frameDuration)
            outputFrameIndex += 1

            if frameIndex == 0 || frameIndex % 30 == 0 {
                let exportProgress = 0.5 + min(0.5, Double(frameIndex) / Double(totalFrames) * 0.5)
                progress?(exportProgress, "Writing valid bbox frame \(frameIndex)")
                DebugLog.mark(
                    "Prescan export: write sourceFrame=\(frameIndex) outputFrame=\(outputFrameIndex) outputTime=\(String(format: "%.3f", outputTime.seconds)) total=\(totalFrames)"
                )
            }
        }

        func sourceFrameDuration(for sample: CMSampleBuffer) -> CMTime {
            let currentTime = CMSampleBufferGetPresentationTimeStamp(sample)
            defer { previousSourceTime = currentTime }

            if let previousSourceTime {
                let delta = CMTimeSubtract(currentTime, previousSourceTime)
                if delta.isValid && delta.seconds > 0 {
                    return delta
                }
            }

            let sampleDuration = CMSampleBufferGetDuration(sample)
            if sampleDuration.isValid && sampleDuration.seconds > 0 {
                return sampleDuration
            }

            return fallbackFrameDuration
        }

        let firstFrameDuration = sourceFrameDuration(for: firstSample)
        if Self.advanceRangeIndex(frameIndex: frameIndex, ranges: scan.ranges, rangeIndex: &rangeIndex) {
            try await append(sample: firstSample, frameIndex: frameIndex, frameDuration: firstFrameDuration)
        }
        frameIndex += 1

        while reader.status == .reading, let sample = readerOutput.copyNextSampleBuffer() {
            let frameDuration = sourceFrameDuration(for: sample)
            if Self.advanceRangeIndex(frameIndex: frameIndex, ranges: scan.ranges, rangeIndex: &rangeIndex) {
                try await append(sample: sample, frameIndex: frameIndex, frameDuration: frameDuration)
            }
            frameIndex += 1
        }

        if reader.status == .failed {
            throw reader.error ?? RunnerPoseError.videoUnreadable(sourceURL)
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw writer.error ?? RunnerPoseError.videoExportFailed("AVAssetWriter failed.")
        }

        progress?(1, "Prescan bbox export complete")
        DebugLog.mark(
            "Prescan export: complete outputFrames=\(outputFrameIndex) outputSeconds=\(String(format: "%.3f", outputTime.seconds)) path=\(destination.path)"
        )
        return destination
    }

    private static func collectPrescanOverlays(
        asset: AVAsset,
        track: AVAssetTrack,
        detector: PersonDetector,
        config: Config,
        fps: Double,
        totalFrames: Int,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> PrescanOverlayScan {
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        guard reader.startReading() else {
            throw reader.error ?? RunnerPoseError.videoUnreadable((asset as? AVURLAsset)?.url ?? URL(fileURLWithPath: ""))
        }

        let stride = max(1, config.prescanStride)
        let bufferFrames = Int((config.prescanBufferSec * fps).rounded())
        let maxGapFrames = Int((config.prescanMaxGapSec * fps).rounded())
        var overlays: [Int: PrescanOverlay] = [:]
        var hitFrames: [Int] = []
        var frameIndex = 0
        var sampledFrames = 0

        while reader.status == .reading, let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            defer { frameIndex += 1 }

            guard frameIndex % stride == 0,
                  let buffer = CMSampleBufferGetImageBuffer(sample) else {
                continue
            }

            let frameSize = CGSize(
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer)
            )
            let detections = try await detector.detect(buffer, frameSize: frameSize)
            let picked = detector.pickRunner(detections, near: nil, frameSize: frameSize, config: config)
            overlays[frameIndex] = PrescanOverlay(detections: detections, picked: picked)
            sampledFrames += 1
            if picked != nil {
                hitFrames.append(frameIndex)
            }

            if sampledFrames == 1 || sampledFrames % 10 == 0 {
                let scanProgress = min(0.5, Double(frameIndex) / Double(totalFrames) * 0.5)
                progress?(scanProgress, "Scanning YOLO frame \(frameIndex)")
                DebugLog.mark(
                    "Prescan export: scan frame=\(frameIndex) detections=\(detections.count) picked=\(picked != nil) sampled=\(sampledFrames) hits=\(hitFrames.count)"
                )
            }
        }

        if reader.status == .failed {
            throw reader.error ?? RunnerPoseError.videoUnreadable((asset as? AVURLAsset)?.url ?? URL(fileURLWithPath: ""))
        }

        let ranges = PrescanFilter.mergeHitFrames(
            hitFrames,
            totalFrames: totalFrames,
            stride: stride,
            bufferFrames: bufferFrames,
            maxGapFrames: maxGapFrames
        )

        DebugLog.mark("Prescan export: scan complete sampled=\(sampledFrames) hits=\(hitFrames.count) ranges=\(ranges.count)")
        return PrescanOverlayScan(overlays: overlays, ranges: ranges)
    }

    private static func advanceRangeIndex(
        frameIndex: Int,
        ranges: [PrescanFilter.FrameRange],
        rangeIndex: inout Int
    ) -> Bool {
        while rangeIndex < ranges.count, frameIndex > ranges[rangeIndex].endFrame {
            rangeIndex += 1
        }
        guard rangeIndex < ranges.count else { return false }
        let range = ranges[rangeIndex]
        return frameIndex >= range.startFrame && frameIndex <= range.endFrame
    }

    private static let bones: [(JointName, JointName)] = [
        (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip), (.leftHip, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        (.leftAnkle, .leftHeel), (.leftAnkle, .leftBigToe), (.leftBigToe, .leftSmallToe),
        (.rightAnkle, .rightHeel), (.rightAnkle, .rightBigToe), (.rightBigToe, .rightSmallToe),
    ]

    private static func draw(pose: RunnerPose, onto pixelBuffer: CVPixelBuffer, frameSize: CGSize) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return }

        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        if let bbox = pose.bbox {
            context.setStrokeColor(CGColor(red: 0, green: 1, blue: 0.1, alpha: 1))
            context.setLineWidth(max(2, frameSize.width / 360))
            context.stroke(bbox.cgRect)
        }

        let joints = Dictionary(uniqueKeysWithValues: pose.joints.map { ($0.name, $0) })
        context.setStrokeColor(CGColor(red: 0, green: 1, blue: 0.1, alpha: 1))
        context.setLineWidth(max(2, frameSize.width / 420))
        for (startName, endName) in bones {
            guard let start = joints[startName], let end = joints[endName] else { continue }
            guard start.score > 0.05, end.score > 0.05 else { continue }
            context.move(to: CGPoint(x: start.x, y: start.y))
            context.addLine(to: CGPoint(x: end.x, y: end.y))
            context.strokePath()
        }

        for joint in pose.joints where joint.score > 0.05 {
            let radius = max(3, frameSize.width / 240)
            let rect = CGRect(x: joint.x - radius, y: joint.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(CGColor(red: 1, green: 0.9, blue: 0, alpha: 1))
            context.fillEllipse(in: rect)
        }
    }

    private static func drawPrescan(overlay: PrescanOverlay, onto pixelBuffer: CVPixelBuffer, frameSize: CGSize) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return }

        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let lineWidth = max(3, frameSize.width / 300)
        for detection in overlay.detections {
            let isPicked = overlay.picked.map { $0.box == detection.box } ?? false
            context.setStrokeColor(
                isPicked
                    ? CGColor(red: 0, green: 1, blue: 0.1, alpha: 1)
                    : CGColor(red: 0, green: 0.8, blue: 1, alpha: 0.85)
            )
            context.setLineWidth(isPicked ? lineWidth * 1.5 : lineWidth)
            context.stroke(detection.box.cgRect)
        }

        let markerSize = max(18, frameSize.width / 28)
        let markerRect = CGRect(x: 12, y: 12, width: markerSize, height: markerSize)
        if overlay.picked != nil {
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0.1, alpha: 0.9))
        } else {
            context.setFillColor(CGColor(red: 1, green: 0.1, blue: 0.05, alpha: 0.9))
        }
        context.fillEllipse(in: markerRect)
    }

    private static func makePixelBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else {
            throw RunnerPoseError.videoExportFailed("Cannot access output pixel buffer pool.")
        }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw RunnerPoseError.videoExportFailed("Cannot allocate output pixel buffer from pool (status \(status)).")
        }
        return pixelBuffer
    }

    private static func defaultOutputURL(sourceURL: URL) throws -> URL {
        try defaultOutputURL(sourceURL: sourceURL, suffix: "pose-overlay")
    }

    private static func defaultOutputURL(sourceURL: URL, suffix: String) throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let basename = sourceURL.deletingPathExtension().lastPathComponent
        let stamp = Int(Date().timeIntervalSince1970)
        return documents.appendingPathComponent("\(basename)-\(suffix)-\(stamp).mp4")
    }
}
