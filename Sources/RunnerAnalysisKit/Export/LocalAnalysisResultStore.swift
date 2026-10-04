import CryptoKit
import Foundation

/// Minimal Step 7 bundle store. Step 8 extends this boundary with disk-space
/// policy, recovery and the complete artifact set; this implementation already
/// guarantees that a completed directory is never exposed before all files are written.
public actor LocalAnalysisResultStore: AnalysisResultStoring {
    private let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public func finalize(
        manifest draft: AnalysisResultManifest,
        pose2D: Analysis2DResult
    ) async throws -> StoredAnalysisResult {
        try Task.checkCancellation()
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let finalURL = rootURL.appendingPathComponent(draft.runID.uuidString, isDirectory: true)
        let stagingURL = rootURL.appendingPathComponent(".\(draft.runID.uuidString).staging", isDirectory: true)
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw RunnerAnalysisError.storageFailed("Result bundle already exists: \(finalURL.path)")
        }
        if fileManager.fileExists(atPath: stagingURL.path) {
            try fileManager.removeItem(at: stagingURL)
        }

        do {
            let poseDirectory = stagingURL.appendingPathComponent("pose", isDirectory: true)
            let diagnosticsDirectory = stagingURL.appendingPathComponent("diagnostics", isDirectory: true)
            try fileManager.createDirectory(at: poseDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)

            let encoder = Self.encoder()
            let poseData = try encoder.encode(Pose2DArtifactDocument(frames: pose2D.frames))
            let poseURL = poseDirectory.appendingPathComponent("keypoints_2d.json")
            try poseData.write(to: poseURL, options: .atomic)

            var manifest = draft
            manifest.artifacts.append(Self.artifact(
                type: .pose2d,
                mediaType: "application/json",
                relativePath: "pose/keypoints_2d.json",
                data: poseData,
                cameraIndex: pose2D.frames.first?.cameraIndex
            ))

            if let diagnostics = pose2D.diagnosticsJSON {
                let diagnosticsURL = diagnosticsDirectory.appendingPathComponent("runner_pose_bench.json")
                try diagnostics.write(to: diagnosticsURL, options: .atomic)
                manifest.artifacts.append(Self.artifact(
                    type: .diagnostics,
                    mediaType: "application/json",
                    relativePath: "diagnostics/runner_pose_bench.json",
                    data: diagnostics
                ))
            }

            try Task.checkCancellation()
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(
                to: stagingURL.appendingPathComponent("manifest.json"),
                options: .atomic
            )
            try Task.checkCancellation()
            try fileManager.moveItem(at: stagingURL, to: finalURL)
            return StoredAnalysisResult(bundleURL: finalURL, manifest: manifest)
        } catch {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
            throw error
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func artifact(
        type: AnalysisArtifactType,
        mediaType: String,
        relativePath: String,
        data: Data,
        cameraIndex: Int? = nil
    ) -> AnalysisArtifactDescriptor {
        AnalysisArtifactDescriptor(
            type: type,
            mediaType: mediaType,
            relativePath: relativePath,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            sizeBytes: data.count,
            cameraIndex: cameraIndex
        )
    }
}

private struct Pose2DArtifactDocument: Codable {
    var schemaVersion = AnalysisContract.schemaVersion
    var jointOrder = AnalysisCoordinateSystem.wholeBody23JointOrder
    var frames: [Pose2DFrame]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case jointOrder = "joint_order"
        case frames
    }
}
