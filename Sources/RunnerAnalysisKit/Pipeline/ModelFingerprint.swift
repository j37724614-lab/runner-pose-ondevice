import CoreML
import CryptoKit
import Foundation

/// Identifies the exact model resource a Local run loaded, for the manifest's
/// `engine.models`. A `.mlmodel` is a file; `.mlpackage` and `.mlmodelc` are
/// directories, hashed as sorted `relative_path\0file_sha256\n` lines so the
/// digest does not depend on file-system enumeration order.
enum ModelFingerprint {
    static func descriptor(
        name: String,
        url: URL,
        computeUnits: MLComputeUnits?
    ) throws -> AnalysisModelDescriptor {
        AnalysisModelDescriptor(
            name: name,
            sha256: try sha256(of: url),
            computeUnits: computeUnits.map(label)
        )
    }

    static func sha256(of url: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw RunnerAnalysisError.processingFailed("Model resource missing at \(url.path).")
        }
        guard isDirectory.boolValue else { return try fileSHA256(url) }

        let root = url.resolvingSymlinksInPath().standardizedFileURL
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var lines: [String] = []
        while let file = enumerator?.nextObject() as? URL {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let relativePath = String(
                file.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(root.path.count + 1)
            )
            lines.append("\(relativePath)\0\(try fileSHA256(file))\n")
        }
        let manifest = lines.sorted().joined()
        return hex(SHA256.hash(data: Data(manifest.utf8)))
    }

    private static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func label(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: return "cpu_only"
        case .cpuAndGPU: return "cpu_and_gpu"
        case .cpuAndNeuralEngine: return "cpu_and_neural_engine"
        case .all: return "all"
        @unknown default: return "unknown"
        }
    }
}
