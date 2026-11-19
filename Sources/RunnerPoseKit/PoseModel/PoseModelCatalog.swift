import Foundation

/// The pose model specs bundled in `Resources/PoseModels/`, and the decoder for each.
///
/// Wiring (TODO(mac)): `RunnerPoseEngine` / `PosePipeline` still construct `HRNetRunner` and
/// `HeatmapDecoder` directly. The next step is to have them take
/// `spec = try PoseModelCatalog.spec(named: config.poseModelID)`,
/// `estimator: any PoseEstimator` and `decoder = try PoseModelCatalog.decoder(for: spec, config:)`,
/// call `estimator.predictOutput(crop:)` + `decoder.decode(...)` + `CanonicalJoints.map(...)`,
/// and size `CropWarp` from `spec.input`. Left for when the uncommitted 2026-10-20 changes to
/// PosePipeline.swift / HeatmapDecoder.swift are committed, so the two edits do not collide.
public enum PoseModelCatalog {
    /// The model used when nothing else is configured.
    public static let defaultModelID = "hrnet_w48_wholebody23"
    static let directory = "PoseModels"

    /// Every valid bundled spec.
    public static func all() throws -> [PoseModelSpec] {
        try specURLs().map { try PoseModelSpec.load(from: $0) }
    }

    /// The bundled spec whose id or alias is `name`.
    public static func spec(named name: String) throws -> PoseModelSpec {
        let specs = try all()
        if let spec = specs.first(where: { $0.names.contains(name) }) {
            return spec
        }
        throw PoseModelSpecError.notFound(name, available: specs.flatMap(\.names))
    }

    /// A spec the phone can run: not a template, and with a Core ML section.
    public static func runnableSpec(named name: String) throws -> PoseModelSpec {
        let spec = try spec(named: name)
        guard spec.status != .template, spec.coreml != nil else {
            throw PoseModelSpecError.notRunnableOnDevice(spec.id)
        }
        return spec
    }

    /// The decoder for a spec's `decoder` field.
    static func decoder(for spec: PoseModelSpec, config: Config) throws -> any KeypointDecoder {
        switch spec.decoder {
        case .darkHeatmap:
            return DarkHeatmapKeypointDecoder(decoder: HeatmapDecoder(config: config))
        case .simccArgmax:
            return try SimCCKeypointDecoder(spec: spec)
        case .argmaxHeatmap:
            // TODO(mac): plain argmax heatmap decoding (no DarkPose refinement) if a model needs it.
            throw PoseModelSpecError.invalid(id: spec.id, "argmax_heatmap decoder is not implemented on device yet")
        }
    }

    private static func specURLs() -> [URL] {
        // TODO(mac): from the Flutter plugin the resources may live in another bundle; mirror
        // ModelResources.locate's bundle search if Bundle.module does not find them there.
        Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: directory) ?? []
    }
}
