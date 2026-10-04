import CoreML
import Foundation

/// Locate a bundled Core ML model regardless of whether the build system left it as a
/// source `.mlpackage` (`swift build`) or a compiled `.mlmodelc` (Xcode app/framework
/// build). Returns the URL and whether it still needs `MLModel.compileModel`.
enum ModelResources {
    private final class BundleToken {}

    struct Located {
        var url: URL
        var needsCompile: Bool
    }

    static func locate(_ name: String) throws -> Located {
        for bundle in candidateBundles {
            if let c = bundle.url(forResource: name, withExtension: "mlmodelc") {
                return Located(url: c, needsCompile: false)
            }
            if let p = bundle.url(forResource: name, withExtension: "mlpackage") {
                return Located(url: p, needsCompile: true)
            }
            if let m = bundle.url(forResource: name, withExtension: "mlmodel") {
                return Located(url: m, needsCompile: true)
            }
        }
        throw RunnerPoseError.modelResourceMissing("\(name).mlpackage")
    }

    static func exists(_ name: String) -> Bool {
        (try? locate(name)) != nil
    }

    private static var candidateBundles: [Bundle] {
        var bundles: [Bundle] = []
#if SWIFT_PACKAGE
        bundles.append(.module)
#endif
        let frameworkBundle = Bundle(for: BundleToken.self)
        if let resourceURL = frameworkBundle.url(
            forResource: "RunnerPoseKitResources",
            withExtension: "bundle"
        ), let resourceBundle = Bundle(url: resourceURL) {
            bundles.append(resourceBundle)
        }
        bundles.append(frameworkBundle)
        bundles.append(.main)
        return bundles
    }
}
