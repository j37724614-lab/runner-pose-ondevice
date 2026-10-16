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
        let perFrameDiagnostics = Data("camera_index,frame,footprint_mb\n0,1,512\n".utf8)
        let overlaySource = root.appendingPathComponent("source-overlay.mp4")
        let overlayData = Data("hrnet-overlay".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try overlayData.write(to: overlaySource)
        let result = Analysis2DResult(
            frames: [sampleFrame()],
            durationSeconds: 1.25,
            diagnosticsJSON: diagnostics,
            perFrameDiagnosticsCSV: perFrameDiagnostics,
            overlayVideoURL: overlaySource
        )
        let resourceSampler = AnalysisResourceSampler(interval: 60)
        resourceSampler.start(stage: .validating)
        resourceSampler.setStage(.export)

        let stored = try await store.finalize(
            manifest: sampleManifest(runID: runID),
            pose2D: result,
            resourceSampler: resourceSampler
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
        let overlayURL = stored.bundleURL.appendingPathComponent("overlay/main.mp4")
        XCTAssertEqual(try Data(contentsOf: overlayURL), overlayData)
        let overlayArtifact = try XCTUnwrap(stored.manifest.artifacts.first { $0.type == .overlay })
        XCTAssertEqual(overlayArtifact.relativePath, "overlay/main.mp4")
        XCTAssertEqual(overlayArtifact.sha256, sha256(overlayData))
        XCTAssertEqual(stored.manifest.artifacts.map(\.type), [
            .pose2d, .diagnostics, .diagnostics, .overlay, .diagnostics,
        ])
        XCTAssertEqual(
            try Data(contentsOf: stored.bundleURL
                .appendingPathComponent("diagnostics/runner_pose_frames.csv")),
            perFrameDiagnostics
        )
        let resourceTraceData = try Data(contentsOf: stored.bundleURL
            .appendingPathComponent("diagnostics/resource_trace.json"))
        let resourceTrace = try JSONDecoder().decode(AnalysisResourceTrace.self, from: resourceTraceData)
        XCTAssertEqual(resourceTrace.samplingIntervalSeconds, 60)
        XCTAssertEqual(resourceTrace.samples.last?.stage, .export)
        let manifestData = try Data(contentsOf: stored.bundleURL.appendingPathComponent("manifest.json"))
        let manifestJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        let summary = try XCTUnwrap(manifestJSON["summary"] as? [String: Any])
        XCTAssertEqual(Set(summary.keys), [
            "total_time_seconds", "average_speed_mps", "average_acceleration_mps2",
            "detected_steps", "average_cadence_spm", "average_step_length_m",
            "maximum_speed_mps", "official_jump_distance_m", "takeoff_speed_mps",
            "flight_time_seconds",
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

    func testMultiCameraPoseArtifactKeepsFrameCameraIndicesWithoutClaimingOneCamera() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerAnalysisKitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAnalysisResultStore(rootURL: root)
        let runID = UUID()
        let cameraZero = sampleFrame(cameraIndex: 0, sourceFrame: 4)
        let cameraOne = sampleFrame(cameraIndex: 1, sourceFrame: 9)

        let stored = try await store.finalize(
            manifest: sampleManifest(runID: runID),
            pose2D: Analysis2DResult(
                frames: [cameraZero, cameraOne],
                durationSeconds: 2
            )
        )

        let poseArtifact = try XCTUnwrap(stored.manifest.artifacts.first { $0.type == .pose2d })
        XCTAssertNil(poseArtifact.cameraIndex)

        let poseData = try Data(
            contentsOf: stored.bundleURL.appendingPathComponent("pose/keypoints_2d.json")
        )
        let decoder = JSONDecoder()
        let document = try decoder.decode(Pose2DArtifactDocument.self, from: poseData)
        XCTAssertEqual(document.frames.map(\.cameraIndex), [0, 1])
        XCTAssertEqual(document.frames.map(\.sourceFrame), [4, 9])
    }

    func testWritesThreeDimensionalPoseAndTraceableAngles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerAnalysisKitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAnalysisResultStore(rootURL: root)
        let runID = UUID()
        var joints: [Pose3DJoint] = []
        joints.reserveCapacity(17)
        for index in 0..<17 {
            joints.append(Pose3DJoint(
                x: Double(index),
                y: Double(index + 1),
                z: Double(index + 2)
            ))
        }
        let frame = Pose3DFrame(
            cameraIndex: 0,
            sourceFrame: 4,
            timestampSeconds: 0.2,
            joints: joints
        )
        let angle = AnalysisAngleFrame(
            cameraIndex: 0,
            sourceFrame: 4,
            timestampSeconds: 0.2,
            rawValuesDegrees: ["left_knee_angle": 130],
            valuesDegrees: ["left_knee_angle": 50]
        )

        let stored = try await store.finalize(
            manifest: sampleManifest(runID: runID),
            pose2D: Analysis2DResult(frames: [sampleFrame()], durationSeconds: 1),
            pose3D: Analysis3DResult(
                frames: [frame],
                angles: [angle],
                durationSeconds: 0.5
            )
        )

        let poseData = try Data(contentsOf: stored.bundleURL
            .appendingPathComponent("pose/keypoints_3d.json"))
        let angleData = try Data(contentsOf: stored.bundleURL.appendingPathComponent("angles.json"))
        let decoder = JSONDecoder()
        let poseDocument = try decoder.decode(Pose3DArtifactDocument.self, from: poseData)
        let angleDocument = try decoder.decode(AnalysisAnglesArtifactDocument.self, from: angleData)
        let expectedPoseFrames: [Pose3DFrame] = [frame]
        let expectedAngleFrames: [AnalysisAngleFrame] = [angle]
        let expectedArtifactTypes: [AnalysisArtifactType] = [.pose2d, .pose3d, .angles]
        XCTAssertEqual(poseDocument.frames, expectedPoseFrames)
        XCTAssertEqual(angleDocument.frames, expectedAngleFrames)
        XCTAssertEqual(stored.manifest.artifacts.map(\.type), expectedArtifactTypes)
        XCTAssertEqual(stored.manifest.artifacts.first { $0.type == .pose3d }?.sha256, sha256(poseData))
        XCTAssertEqual(stored.manifest.artifacts.first { $0.type == .angles }?.sha256, sha256(angleData))
    }

    func testWritesKinematicsArtifactAndManifestSummary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerAnalysisKitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAnalysisResultStore(rootURL: root)
        let runID = UUID()
        let frame = AnalysisKinematicsFrame(
            cameraIndex: 0,
            cameraFrame: 0,
            sourceFrame: 12,
            absoluteFrame: 0,
            timestampSeconds: 0.2,
            distanceM: 1.2,
            rawDistanceM: 1.1,
            smoothDistanceM: 1.2,
            speedMPS: 7.5,
            accelerationMPS2: 2.1,
            speedModeUsed: "homography",
            pixelDistanceM: 1.0,
            pixelSpeedMPS: 7.0,
            pixelAccelerationMPS2: 2.0,
            homographyDistanceM: 1.2,
            homographySpeedMPS: 7.5,
            homographyAccelerationMPS2: 2.1,
            imagePointX: 320,
            imagePointY: 800,
            isInterpolated: false,
            interpolationGapLength: 0,
            confidence: 1
        )

        let stored = try await store.finalize(
            manifest: sampleManifest(runID: runID),
            pose2D: Analysis2DResult(frames: [sampleFrame()], durationSeconds: 1),
            kinematics: AnalysisKinematicsResult(frames: [frame], durationSeconds: 0.1)
        )

        let data = try Data(contentsOf: stored.bundleURL.appendingPathComponent("metrics.json"))
        let document = try JSONDecoder().decode(AnalysisKinematicsArtifactDocument.self, from: data)
        XCTAssertEqual(document.frames, [frame])
        let artifact = try XCTUnwrap(stored.manifest.artifacts.first { $0.type == .metrics })
        XCTAssertEqual(artifact.relativePath, "metrics.json")
        XCTAssertEqual(artifact.sha256, sha256(data))
    }

    func testWritesGaitArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerAnalysisKitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAnalysisResultStore(rootURL: root)
        let runID = UUID()
        let gait = AnalysisGaitResult(
            legIdentityFrames: [AnalysisLegIdentityFrame(
                cameraIndex: 0,
                sourceFrame: 12,
                timestampSeconds: 0.2,
                leftSource: .detectedLeft,
                rightSource: .detectedRight,
                swapped: false,
                confidence: 0.9,
                reason: .none
            )],
            contactEvents: [AnalysisContactEvent(
                eventIndex: 0,
                eventType: .heelStrike,
                foot: .left,
                cameraIndex: 0,
                sourceFrame: 12,
                timestampSeconds: 0.2,
                contactJoint: .heel,
                imagePoint: AnalysisPoint(x: 320, y: 800),
                worldPointM: AnalysisPoint(x: 1.2, y: 0.4),
                confidence: 0.9,
                reason: "test"
            )],
            steps: AnalysisStepsArtifactDocument(
                averageStepLengthM: 1.2,
                averageStrideLengthM: nil,
                averageCadenceSPM: 240,
                steps: [AnalysisStepSample(
                    stepIndex: 1,
                    eventType: .step,
                    foot: .left,
                    cameraIndex: 0,
                    sourceFrame: 12,
                    timestampSeconds: 0.2,
                    worldXM: 1.2,
                    worldYM: 0.4,
                    confidence: 0.9
                )]
            ),
            durationSeconds: 0.01
        )

        let stored = try await store.finalize(
            manifest: sampleManifest(runID: runID),
            pose2D: Analysis2DResult(frames: [sampleFrame()], durationSeconds: 1),
            gait: gait
        )

        XCTAssertEqual(stored.manifest.artifacts.map(\.type), [
            .pose2d, .legIdentity, .contacts, .steps,
        ])
        let contactsData = try Data(contentsOf: stored.bundleURL
            .appendingPathComponent("gait/contacts.json"))
        let contacts = try JSONDecoder().decode(
            AnalysisContactEventsArtifactDocument.self,
            from: contactsData
        )
        XCTAssertEqual(contacts.events, gait.contactEvents)
        let stepsURL = stored.bundleURL.appendingPathComponent("gait/steps.json")
        let stepsJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stepsURL)) as? [String: Any]
        )
        XCTAssertTrue(stepsJSON["average_stride_length_m"] is NSNull)
        let encodedSteps = try XCTUnwrap(stepsJSON["steps"] as? [[String: Any]])
        XCTAssertTrue(encodedSteps[0]["step_length_m"] is NSNull)
        XCTAssertTrue(encodedSteps[0]["contact_time_seconds"] is NSNull)
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

        XCTAssertEqual(removed.map(\.lastPathComponent), [".old.staging"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldStaging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentStaging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: completed.path))
    }
}

private struct FixedCapacityProvider: AnalysisStorageCapacityProviding {
    var bytes: Int64?
    func availableCapacity(at url: URL) throws -> Int64? { bytes }
}

private func sampleFrame(cameraIndex: Int = 0, sourceFrame: Int = 4) -> Pose2DFrame {
    Pose2DFrame(
        cameraIndex: cameraIndex,
        sourceFrame: sourceFrame,
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
