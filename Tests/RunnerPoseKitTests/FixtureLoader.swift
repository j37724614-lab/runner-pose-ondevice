import CoreML
import Foundation
import XCTest
@testable import RunnerPoseKit

struct GeometryFixture: Decodable {
    var frame_size: [Int]
    var bbox: [Double]
    var center: [Double]
    var scale: [Double]
    var forward_affine_crop: [Double]     // a b tx c d ty
    var inverse_affine_heatmap: [Double]  // a b tx c d ty
}

enum Fixtures {
    /// Names present in the Fixtures/ bundle (empty when not generated yet).
    static func names() -> [String] {
        guard let dir = bundleURL() else { return [] }
        let jsons = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return jsons
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasSuffix(".geometry.json") }
            .map { $0.lastPathComponent.replacingOccurrences(of: ".geometry.json", with: "") }
            .sorted()
    }

    static func geometry(_ name: String) throws -> GeometryFixture {
        try JSONDecoder().decode(GeometryFixture.self, from: Data(contentsOf: url("\(name).geometry.json")))
    }

    static func keypoints(_ name: String) throws -> [[Double]] {
        try JSONDecoder().decode([[Double]].self, from: Data(contentsOf: url("\(name).keypoints.json")))
    }

    /// Raw heatmap -> MLMultiArray [1,23,96,72] float32.
    static func heatmap(_ name: String) throws -> MLMultiArray {
        let data = try Data(contentsOf: url("\(name).heatmap.f32"))
        let count = 23 * 96 * 72
        precondition(data.count == count * MemoryLayout<Float32>.size, "bad heatmap fixture size")
        let arr = try MLMultiArray(shape: [1, 23, 96, 72], dataType: .float32)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Float32.self)
            let dst = arr.dataPointer.bindMemory(to: Float32.self, capacity: count)
            for i in 0..<count { dst[i] = src[i] }
        }
        return arr
    }

    private static func url(_ file: String) -> URL {
        bundleURL()!.appendingPathComponent(file)
    }

    private static func bundleURL() -> URL? {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)
            ?? Bundle.module.resourceURL?.appendingPathComponent("Fixtures")
    }
}

/// Prints a skip note and returns true when there are no fixtures yet.
func skipIfNoFixtures(_ file: StaticString = #filePath, _ line: UInt = #line) -> Bool {
    if Fixtures.names().isEmpty {
        print("⏭  no parity fixtures — run scripts/dump_parity_fixtures.py (see Fixtures/README.md)")
        return true
    }
    return false
}
