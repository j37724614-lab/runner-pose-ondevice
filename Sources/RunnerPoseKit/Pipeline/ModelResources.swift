import CoreML
import Foundation

/// Locate a bundled Core ML model regardless of whether the build system left it as a
/// source `.mlpackage` (`swift build`) or a compiled `.mlmodelc` (Xcode app/framework
/// build). Returns the URL and whether it still needs `MLModel.compileModel`.
enum ModelResources {
    struct Located {
        var url: URL
        var needsCompile: Bool
    }

    static func locate(_ name: String) throws -> Located {
        if let c = Bundle.module.url(forResource: name, withExtension: "mlmodelc") {
            return Located(url: c, needsCompile: false)
        }
        if let p = Bundle.module.url(forResource: name, withExtension: "mlpackage") {
            return Located(url: p, needsCompile: true)
        }
        if let m = Bundle.module.url(forResource: name, withExtension: "mlmodel") {
            return Located(url: m, needsCompile: true)
        }
        throw RunnerPoseError.modelResourceMissing("\(name).mlpackage")
    }

    static func exists(_ name: String) -> Bool {
        (try? locate(name)) != nil
    }
}
