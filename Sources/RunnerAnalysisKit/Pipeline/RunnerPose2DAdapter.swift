import CoreML
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
        let engine = try await RunnerPoseEngine(config: config)
        await engine.warmUp()
        let models = try RunnerPoseEngine.modelResources(for: config).map { resource in
            try ModelFingerprint.descriptor(
                name: resource.name,
                url: resource.url,
                // UltralyticsYOLO picks its own compute units; only HRNet uses config's.
                computeUnits: resource.name == config.detectorModel.rawValue ? nil : config.computeUnits
            )
        }
        var frames: [Pose2DFrame] = []
        var reports: [Any] = []
        var durationSeconds: Double = 0
        let cameras = request.cameras.sorted { $0.cameraIndex < $1.cameraIndex }
        var singleCameraPoses: [RunnerPose]?

        for camera in cameras {
            try Task.checkCancellation()
            let videoURL = try Self.videoURL(from: camera.video.uri)
            let conditions = RunnerPoseEngine.baseConditions(
                videoName: videoURL.lastPathComponent,
                implementationVariant: "runner-analysis-kit-camera-\(camera.cameraIndex)"
            )
            let output = try await engine.analyze(
                videoURL,
                conditions: conditions,
                regionOfInterest: Self.regionOfInterest(from: camera.calibration)
            )
            if cameras.count == 1 {
                singleCameraPoses = output.poses
            }
            frames.append(contentsOf: output.poses.map {
                Self.contractFrame($0, cameraIndex: camera.cameraIndex)
            })
            durationSeconds += output.report.totals.wallClockSeconds
            if let object = try? JSONSerialization.jsonObject(with: output.report.jsonData()) {
                reports.append(object)
            }
        }

        let overlayURL: URL?
        if request.outputPolicy.includeOverlays,
           let camera = cameras.first,
           let singleCameraPoses {
            let videoURL = try Self.videoURL(from: camera.video.uri)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("runner-pose-overlay-\(UUID().uuidString).mp4")
            do {
                overlayURL = try await RunnerPoseVideoExporter.exportOverlayVideo(
                    sourceURL: videoURL,
                    poses: singleCameraPoses,
                    outputURL: destination
                )
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        } else {
            overlayURL = nil
        }
        let diagnostics = try? JSONSerialization.data(
            withJSONObject: ["camera_reports": reports],
            options: [.prettyPrinted, .sortedKeys]
        )
        return Analysis2DResult(
            frames: frames,
            durationSeconds: durationSeconds,
            diagnosticsJSON: diagnostics,
            overlayVideoURL: overlayURL,
            models: models
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

    static func regionOfInterest(
        from calibration: AnalysisCalibration?
    ) -> RunnerRegionOfInterest? {
        guard let calibration else { return nil }
        if let start = calibration.startLine, start.count == 2,
           let end = calibration.endLine, end.count == 2 {
            return RunnerRegionOfInterest(points: [
                RunnerRegionPoint(x: start[0].x, y: start[0].y),
                RunnerRegionPoint(x: end[0].x, y: end[0].y),
                RunnerRegionPoint(x: end[1].x, y: end[1].y),
                RunnerRegionPoint(x: start[1].x, y: start[1].y),
            ])
        }
        guard let x = calibration.roiX, x.count == 2,
              let y = calibration.roiY, y.count == 2 else { return nil }
        return RunnerRegionOfInterest(points: [
            RunnerRegionPoint(x: x[0], y: y[0]),
            RunnerRegionPoint(x: x[1], y: y[0]),
            RunnerRegionPoint(x: x[1], y: y[1]),
            RunnerRegionPoint(x: x[0], y: y[1]),
        ])
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
