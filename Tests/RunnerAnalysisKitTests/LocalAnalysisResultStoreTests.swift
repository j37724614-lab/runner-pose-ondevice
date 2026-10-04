import CryptoKit
import Foundation
import XCTest
@testable import RunnerAnalysisKit

final class LocalAnalysisResultStoreTests: XCTestCase {
    func testWritesPoseDiagnosticsAndManifestThenPublishesBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerAnalysisKitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAnalysisResultStore(rootURL: root)
        let runID = UUID()
        let diagnostics = Data(#"{"ok":true}"#.utf8)
        let result = Analysis2DResult(
            frames: [sampleFrame()],
            durationSeconds: 1.25,
            diagnosticsJSON: diagnostics
        )

        let stored = try await store.finalize(
            manifest: sampleManifest(runID: runID),
            pose2D: result
        )

        XCTAssertEqual(stored.bundleURL.lastPathComponent, runID.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stored.bundleURL.appendingPathComponent("manifest.json").path
        ))
        let digestURL = stored.bundleURL.appendingPathComponent("manifest.sha256")
        let digestLine = try String(contentsOf: digestURL, encoding: .utf8)
        let writtenManifest = try Data(
            contentsOf: stored.bundleURL.appendingPathComponent("manifest.json")
        )
        XCTAssertEqual(digestLine, "\(sha256(writtenManifest))  manifest.json\n")
        let poseURL = stored.bundleURL.appendingPathComponent("pose/keypoints_2d.json")
        let poseData = try Data(contentsOf: poseURL)
        let poseArtifact = try XCTUnwrap(stored.manifest.artifacts.first { $0.type == .pose2d })
        XCTAssertEqual(poseArtifact.sizeBytes, poseData.count)
        XCTAssertEqual(poseArtifact.sha256, sha256(poseData))
        XCTAssertEqual(stored.manifest.artifacts.map(\.type), [.pose2d, .diagnostics])
        let manifestData = try Data(contentsOf: stored.bundleURL.appendingPathComponent("manifest.json"))
        let manifestJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        let summary = try XCTUnwrap(manifestJSON["summary"] as? [String: Any])
        XCTAssertEqual(Set(summary.keys), [
            "total_time_seconds", "average_speed_mps", "average_acceleration_mps2",
            "detected_steps", "average_cadence_spm", "average_step_length_m",
        ])
        XCTAssertTrue(summary["average_speed_mps"] is NSNull)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".\(runID.uuidString).staging").path
        ))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try decoder.decode(AnalysisResultManifest.self, from: manifestData),
            stored.manifest
        )
        let decodedPose = try decoder.decode(Pose2DArtifactDocument.self, from: poseData)
        XCTAssertEqual(decodedPose.schemaVersion, AnalysisContract.schemaVersion)
        XCTAssertEqual(decodedPose.jointOrder, AnalysisCoordinateSystem.wholeBody23JointOrder)
        XCTAssertEqual(decodedPose.frames, result.frames)
    }

    func testRejectsWriteWhenFreeSpaceWouldFallBelowReserve() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerAnalysisKitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = UUID()
        let store = LocalAnalysisResultStore(
            rootURL: root,
            policy: LocalAnalysisStoragePolicy(minimumFreeAfterWriteBytes: 1024),
            capacityProvider: FixedCapacityProvider(bytes: 0)
        )

        do {
            _ = try await store.finalize(
                manifest: sampleManifest(runID: runID),
                pose2D: Analysis2DResult(frames: [sampleFrame()], durationSeconds: 1)
            )
            XCTFail("expected insufficient storage")
        } catch let error as RunnerAnalysisError {
            guard case .insufficientStorage = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(runID.uuidString).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".\(runID.uuidString).staging").path
        ))
    }

    func testAlreadyCancelledTaskDoesNotCreateACompletedOrStagingBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerAnalysisKitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = UUID()
        let store = LocalAnalysisResultStore(rootURL: root)

        let task = Task {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return try await store.finalize(
                manifest: sampleManifest(runID: runID),
                pose2D: Analysis2DResult(frames: [sampleFrame()], durationSeconds: 1)
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(runID.uuidString).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".\(runID.uuidString).staging").path
        ))
    }

    func testRecoveryOnlyRemovesOldStagingDirectories() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerAnalysisKitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldStaging = root.appendingPathComponent(".old.staging", isDirectory: true)
        let currentStaging = root.appendingPathComponent(".current.staging", isDirectory: true)
        let completed = root.appendingPathComponent("completed", isDirectory: true)
        for directory in [oldStaging, currentStaging, completed] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: oldStaging.path
        )
        let store = LocalAnalysisResultStore(rootURL: root)

        let removed = try await store.recoverAbandonedStaging(
            olderThan: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(removed, [oldStaging])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldStaging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentStaging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: completed.path))
    }
}

private struct FixedCapacityProvider: AnalysisStorageCapacityProviding {
    var bytes: Int64?
    func availableCapacity(at url: URL) throws -> Int64? { bytes }
}

private func sampleFrame() -> Pose2DFrame {
    Pose2DFrame(
        cameraIndex: 0,
        sourceFrame: 4,
        timestampSeconds: 0.2,
        bbox: Pose2DBoundingBox(x1: 1, y1: 2, x2: 3, y2: 4),
        joints: [Pose2DJoint(x: 10, y: 20, score: 0.8)],
        valid: true,
        bboxExtrapolated: false
    )
}

private func sampleManifest(runID: UUID) -> AnalysisResultManifest {
    AnalysisResultManifest(
        requestID: UUID(),
        runID: runID,
        comparisonGroupID: nil,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        configSha256: String(repeating: "a", count: 64),
        inputVideos: [
            AnalysisInputVideoDescriptor(cameraIndex: 0, sha256: String(repeating: "b", count: 64)),
        ],
        stages: [
            AnalysisStageResult(name: .validating, status: .completed),
            AnalysisStageResult(name: .pose2d, status: .completed),
            AnalysisStageResult(name: .export, status: .completed),
        ],
        warnings: []
    )
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
