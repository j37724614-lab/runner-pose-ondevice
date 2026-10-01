import Accelerate
import CoreVideo
import Foundation

public enum RunnerPoseError: Error, CustomStringConvertible {
    case modelResourceMissing(String)
    case modelLoadFailed(String, underlying: Error)
    case detectorUnavailable(DetectorModel)
    case videoUnreadable(URL)
    case noVideoTrack(URL)
    case videoExportFailed(String)
    case cropWarpSetup(CVReturn)
    case warpFailed(vImage_Error)
    case heatmapShapeMismatch(got: [Int], expected: [Int])
    case cancelled

    public var description: String {
        switch self {
        case .modelResourceMissing(let name):
            return "Model resource '\(name)' not found in the bundle. See Sources/RunnerPoseKit/Resources/README.md."
        case .modelLoadFailed(let name, let underlying):
            return "Failed to load Core ML model '\(name)': \(underlying)"
        case .detectorUnavailable(let m):
            return "Detector \(m.rawValue) is not available (missing resource or unsupported OS)."
        case .videoUnreadable(let url):
            return "Cannot read video at \(url.path)."
        case .noVideoTrack(let url):
            return "No video track in \(url.path)."
        case .videoExportFailed(let message):
            return "Video export failed: \(message)"
        case .cropWarpSetup(let s):
            return "CVPixelBufferPool / buffer setup failed (CVReturn \(s))."
        case .warpFailed(let e):
            return "vImage affine warp failed (\(e))."
        case .heatmapShapeMismatch(let got, let expected):
            return "HRNet output shape \(got), expected \(expected)."
        case .cancelled:
            return "Cancelled."
        }
    }
}
