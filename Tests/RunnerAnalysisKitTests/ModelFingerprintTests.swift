import CoreML
import Foundation
import XCTest
@testable import RunnerAnalysisKit

final class ModelFingerprintTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-fingerprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFileHashIsPlainSHA256() throws {
        let file = root.appendingPathComponent("model.mlmodel")
        try Data("hello".utf8).write(to: file)

        XCTAssertEqual(
            try ModelFingerprint.sha256(of: file),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    func testDirectoryHashCoversSortedRelativePathsAndContents() throws {
        let package = try makeCompiledModel(x: "x", y: "y")

        // sha256 of "model.mil\0sha256(x)\nweights/b.bin\0sha256(y)\n", computed in Python.
        XCTAssertEqual(
            try ModelFingerprint.sha256(of: package),
            "410c4dd3c891774fcf4436dcd4a56527e5249fb8e170f3e967095bff7724b1d6"
        )
        let changedWeights = try makeCompiledModel(x: "x", y: "z", name: "Other")
        XCTAssertNotEqual(
            try ModelFingerprint.sha256(of: package),
            try ModelFingerprint.sha256(of: changedWeights)
        )
    }

    func testDescriptorLabelsComputeUnits() throws {
        let file = root.appendingPathComponent("model.mlmodel")
        try Data("hello".utf8).write(to: file)

        let descriptor = try ModelFingerprint.descriptor(
            name: "HRNetRunnerWholeBody23",
            url: file,
            computeUnits: .cpuAndNeuralEngine
        )

        XCTAssertEqual(descriptor.name, "HRNetRunnerWholeBody23")
        XCTAssertEqual(descriptor.computeUnits, "cpu_and_neural_engine")
    }

    func testMissingResourceThrows() {
        XCTAssertThrowsError(try ModelFingerprint.sha256(of: root.appendingPathComponent("missing")))
    }

    private func makeCompiledModel(x: String, y: String, name: String = "Model") throws -> URL {
        let package = root.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        let weights = package.appendingPathComponent("weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data(x.utf8).write(to: package.appendingPathComponent("model.mil"))
        try Data(y.utf8).write(to: weights.appendingPathComponent("b.bin"))
        return package
    }
}
