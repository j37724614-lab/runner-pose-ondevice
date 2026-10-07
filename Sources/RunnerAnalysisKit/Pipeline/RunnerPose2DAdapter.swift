import CoreMedia
import Foundation
import RunnerPoseKit

/// Step 7 adapter that keeps RunnerPoseKit usable on its own while making its
/// existing S0-S5 pipeline an implementation detail of RunnerAnalysisEngine.
public actor RunnerPose2DAdapter: Analysis2DProcessing {
    private let config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    public func process(request: AnalysisRequest) async throws -> Analysis2DResult {
        guard request.cameras.count == 1, let camera = request.cameras.first else {
            throw RunnerAnalysisError.invalidRequest(
                "Step 7 supports exactly one camera; multi-camera processing starts at Step 15."
            )
        }

        let videoURL = try Self.videoURL(from: camera.video.uri)
        let engine = try await RunnerPoseEngine(config: config)
        await engine.warmUp()
        let conditions = await RunnerPoseEngine.baseConditions(
            videoName: videoURL.lastPathComponent,
            implementationVariant: "runner-analysis-kit"
        )
        let output = try await engine.analyze(videoURL, conditions: conditions)
        let frames = output.poses.map { Self.contractFrame($0, cameraIndex: camera.cameraIndex) }
        let overlayURL: URL?
        if request.outputPolicy.includeOverlays {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("runner-pose-overlay-\(UUID().uuidString).mp4")
            do {
                overlayURL = try await RunnerPoseVideoExporter.exportOverlayVideo(
                    sourceURL: videoURL,
                    poses: output.poses,
                    outputURL: destination
                )
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        } else {
            overlayURL = nil
        }
        return Analysis2DResult(
            frames: frames,
            durationSeconds: output.report.totals.wallClockSeconds,
            diagnosticsJSON: try output.report.jsonData(),
            overlayVideoURL: overlayURL
        )
    }

    static func contractFrame(_ pose: RunnerPose, cameraIndex: Int) -> Pose2DFrame {
        Pose2DFrame(
            cameraIndex: cameraIndex,
            sourceFrame: pose.frameIndex,
            timestampSeconds: pose.timestamp.seconds,
            bbox: pose.bbox.map {
                Pose2DBoundingBox(x1: $0.x1, y1: $0.y1, x2: $0.x2, y2: $0.y2)
            },
            joints: pose.joints.map { Pose2DJoint(x: $0.x, y: $0.y, score: $0.score) },
            valid: pose.valid,
            bboxExtrapolated: pose.bboxExtrapolated
        )
    }

    private static func videoURL(from uri: String) throws -> URL {
        let url: URL
        if let parsed = URL(string: uri), parsed.isFileURL {
            url = parsed
        } else {
            url = URL(fileURLWithPath: uri)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RunnerAnalysisError.invalidRequest("Input video does not exist: \(url.path)")
        }
        return url
    }
}
