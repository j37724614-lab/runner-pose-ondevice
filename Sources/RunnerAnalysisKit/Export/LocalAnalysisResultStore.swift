import CryptoKit
import Foundation

public struct LocalAnalysisStoragePolicy: Sendable, Equatable {
    /// Free space that must remain after publishing a bundle.
    public var minimumFreeAfterWriteBytes: Int64
    public var abandonedStagingAge: TimeInterval

    public init(
        minimumFreeAfterWriteBytes: Int64 = 64 * 1024 * 1024,
        abandonedStagingAge: TimeInterval = 24 * 60 * 60
    ) {
        self.minimumFreeAfterWriteBytes = minimumFreeAfterWriteBytes
        self.abandonedStagingAge = abandonedStagingAge
    }
}

public protocol AnalysisStorageCapacityProviding: Sendable {
    func availableCapacity(at url: URL) throws -> Int64?
}

public struct VolumeStorageCapacityProvider: AnalysisStorageCapacityProviding {
    public init() {}

    public func availableCapacity(at url: URL) throws -> Int64? {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let importantUsage = values.volumeAvailableCapacityForImportantUsage {
            return importantUsage
        }
        if let available = values.volumeAvailableCapacity {
            return Int64(available)
        }
        return nil
    }
}

/// Writes a result bundle into a hidden staging directory and only publishes it
/// after every artifact, the manifest and its digest have been written.
public actor LocalAnalysisResultStore: AnalysisResultStoring {
    private let rootURL: URL
    private let fileManager: FileManager
    private let policy: LocalAnalysisStoragePolicy
    private let capacityProvider: any AnalysisStorageCapacityProviding

    public init(
        rootURL: URL,
        fileManager: FileManager = .default,
        policy: LocalAnalysisStoragePolicy = LocalAnalysisStoragePolicy(),
        capacityProvider: any AnalysisStorageCapacityProviding = VolumeStorageCapacityProvider()
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.policy = policy
        self.capacityProvider = capacityProvider
    }

    public func finalize(
        manifest draft: AnalysisResultManifest,
        pose2D: Analysis2DResult
    ) async throws -> StoredAnalysisResult {
        try Task.checkCancellation()
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        _ = try recoverAbandonedStaging(
            olderThan: Date().addingTimeInterval(-policy.abandonedStagingAge)
        )

        let encoder = Self.encoder()
        let poseData = try encoder.encode(Pose2DArtifactDocument(frames: pose2D.frames))
        let expectedWriteBytes = Int64(poseData.count + (pose2D.diagnosticsJSON?.count ?? 0))
            + 1024 * 1024
        if let available = try capacityProvider.availableCapacity(at: rootURL) {
            let required = expectedWriteBytes + policy.minimumFreeAfterWriteBytes
            guard available >= required else {
                throw RunnerAnalysisError.insufficientStorage(
                    requiredBytes: required,
                    availableBytes: available
                )
            }
        }

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
            let manifestURL = stagingURL.appendingPathComponent("manifest.json")
            try manifestData.write(to: manifestURL, options: .atomic)
            let manifestDigest = SHA256.hash(data: manifestData)
                .map { String(format: "%02x", $0) }
                .joined()
            try Data("\(manifestDigest)  manifest.json\n".utf8).write(
                to: stagingURL.appendingPathComponent("manifest.sha256"),
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

    /// Removes incomplete bundles left by an app crash. Only hidden directories
    /// with the exact Step 8 staging suffix and older than the cutoff are touched.
    @discardableResult
    public func recoverAbandonedStaging(olderThan cutoff: Date) throws -> [URL] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let candidates = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        )
        var removed: [URL] = []
        for candidate in candidates {
            let name = candidate.lastPathComponent
            guard name.hasPrefix("."), name.hasSuffix(".staging") else { continue }
            let values = try candidate.resourceValues(forKeys: [
                .isDirectoryKey, .contentModificationDateKey,
            ])
            guard values.isDirectory == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff else { continue }
            try fileManager.removeItem(at: candidate)
            removed.append(candidate)
        }
        return removed.sorted { $0.path < $1.path }
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

struct Pose2DArtifactDocument: Codable, Equatable {
    var schemaVersion = AnalysisContract.schemaVersion
    var jointOrder = AnalysisCoordinateSystem.wholeBody23JointOrder
    var frames: [Pose2DFrame]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case jointOrder = "joint_order"
        case frames
    }
}
