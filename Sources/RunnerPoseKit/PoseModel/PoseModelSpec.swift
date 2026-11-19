import Foundation

/// Description of one 2D pose model, read from a JSON "pose model spec".
///
/// The format is shared with the server: runner-analysis-pipeline
/// `core/pose_models/spec.py` defines and validates it, and
/// `docs/developer/pose_model_spec.md` documents it. This file reads the subset the phone
/// needs (the `server` section is ignored). Bundled specs live in
/// `Resources/PoseModels/` and are copied from the pipeline by
/// `scripts/pose_models/sync_pose_specs.py` — edit them there, not here.
///
/// Swapping the 2D model = add a spec + a Core ML package (+ a `KeypointDecoder` when the
/// output kind is new); the pipeline reads input size, output kind and keypoint mapping
/// from the spec instead of hard-coding HRNet.
public struct PoseModelSpec: Decodable, Sendable, Equatable {
    public static let supportedVersion = 1

    public enum Status: String, Decodable, Sendable {
        case production, experimental, template
    }

    public enum OutputKind: String, Decodable, Sendable {
        case heatmap, simcc
    }

    public enum DecoderName: String, Decodable, Sendable {
        case darkHeatmap = "dark_heatmap"
        case argmaxHeatmap = "argmax_heatmap"
        case simccArgmax = "simcc_argmax"

        /// Output kinds this decoder can read.
        var reads: OutputKind {
            switch self {
            case .darkHeatmap, .argmaxHeatmap: return .heatmap
            case .simccArgmax: return .simcc
            }
        }
    }

    public enum ColorOrder: String, Decodable, Sendable {
        case rgb = "RGB"
        case bgr = "BGR"
    }

    public struct Keypoints: Decodable, Sendable, Equatable {
        public var count: Int
        public var names: [String]?
        /// One entry per canonical (WholeBody23) joint: the native index, or nil when the
        /// model does not predict that joint.
        public var toCanonical: [Int?]?

        enum CodingKeys: String, CodingKey {
            case count, names
            case toCanonical = "to_canonical"
        }
    }

    public struct Input: Decodable, Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var colorOrder: ColorOrder
        public var bboxPadding: Double?

        enum CodingKeys: String, CodingKey {
            case width, height
            case colorOrder = "color_order"
            case bboxPadding = "bbox_padding"
        }
    }

    public struct Output: Decodable, Sendable, Equatable {
        public struct Heatmap: Decodable, Sendable, Equatable {
            public var width: Int
            public var height: Int
        }

        public struct SimCC: Decodable, Sendable, Equatable {
            public var splitRatio: Double

            enum CodingKeys: String, CodingKey {
                case splitRatio = "split_ratio"
            }
        }

        public var kind: OutputKind
        public var heatmap: Heatmap?
        public var simcc: SimCC?
    }

    public struct CoreMLSection: Decodable, Sendable, Equatable {
        /// `.mlpackage` file name in the app's resources.
        public var package: String
        public var inputName: String
        /// Role -> Core ML feature name: `heatmaps`, or `simcc_x` and `simcc_y`.
        public var outputNames: [String: String]
        public var computePrecision: String?

        /// Package name without the `.mlpackage` extension, as `ModelResources.locate` wants it.
        public var resourceName: String {
            (package as NSString).deletingPathExtension
        }

        enum CodingKeys: String, CodingKey {
            case package
            case inputName = "input_name"
            case outputNames = "output_names"
            case computePrecision = "compute_precision"
        }
    }

    public var specVersion: Int
    public var id: String
    public var aliases: [String]
    public var family: String?
    public var status: Status
    public var keypoints: Keypoints
    public var input: Input
    public var output: Output
    public var decoder: DecoderName
    public var coreml: CoreMLSection?

    enum CodingKeys: String, CodingKey {
        case specVersion = "spec_version"
        case id, aliases, family, status, keypoints, input, output, decoder, coreml
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        specVersion = try c.decode(Int.self, forKey: .specVersion)
        id = try c.decode(String.self, forKey: .id)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        family = try c.decodeIfPresent(String.self, forKey: .family)
        status = try c.decode(Status.self, forKey: .status)
        keypoints = try c.decode(Keypoints.self, forKey: .keypoints)
        input = try c.decode(Input.self, forKey: .input)
        output = try c.decode(Output.self, forKey: .output)
        self.decoder = try c.decode(DecoderName.self, forKey: .decoder)
        coreml = try c.decodeIfPresent(CoreMLSection.self, forKey: .coreml)
    }

    /// Every name the spec answers to.
    public var names: [String] { [id] + aliases }

    /// For each canonical joint (`JointName` order), the native output index or nil.
    public var canonicalIndices: [Int?] {
        if let mapping = keypoints.toCanonical { return mapping }
        let native = keypoints.names ?? []
        return JointName.canonicalNames.map { native.firstIndex(of: $0) }
    }

    /// Canonical joints this model does not predict.
    public var missingJoints: [JointName] {
        zip(JointName.allCases, canonicalIndices).compactMap { $1 == nil ? $0 : nil }
    }

    /// Decode and validate one spec file.
    public static func load(from url: URL) throws -> PoseModelSpec {
        let spec = try JSONDecoder().decode(PoseModelSpec.self, from: Data(contentsOf: url))
        try spec.validate()
        return spec
    }

    /// The same rules as the pipeline's `parse_spec`, for the fields the phone reads.
    public func validate() throws {
        func check(_ ok: Bool, _ message: String) throws {
            if !ok { throw PoseModelSpecError.invalid(id: id, message) }
        }
        try check(specVersion == Self.supportedVersion, "spec_version must be \(Self.supportedVersion)")
        try check(input.width > 0 && input.height > 0, "input size must be positive")
        try check(decoder.reads == output.kind, "decoder \(decoder.rawValue) cannot read \(output.kind.rawValue) output")
        let mapping = canonicalIndices
        try check(mapping.count == JointName.count, "to_canonical must have \(JointName.count) entries")
        try check(
            mapping.allSatisfy { $0 == nil || (0..<keypoints.count).contains($0!) },
            "to_canonical entries must be native indices"
        )
        switch output.kind {
        case .heatmap:
            try check(output.heatmap != nil, "heatmap output needs output.heatmap width/height on device")
        case .simcc:
            try check((output.simcc?.splitRatio ?? 0) > 0, "simcc output needs output.simcc.split_ratio")
        }
        if let coreml {
            let expected: Set<String> = output.kind == .heatmap ? ["heatmaps"] : ["simcc_x", "simcc_y"]
            try check(Set(coreml.outputNames.keys) == expected, "coreml.output_names must have keys \(expected.sorted())")
        }
    }

    /// Throw when the model lacks joints an analysis needs (e.g. the long jump needs the feet).
    public func require(_ joints: [JointName], for purpose: String) throws {
        let missing = joints.filter { missingJoints.contains($0) }
        if !missing.isEmpty {
            throw PoseModelSpecError.missingJoints(id: id, missing: missing, purpose: purpose)
        }
    }
}

public enum PoseModelSpecError: Error, CustomStringConvertible, Equatable {
    case invalid(id: String, String)
    case missingJoints(id: String, missing: [JointName], purpose: String)
    case notFound(String, available: [String])
    case notRunnableOnDevice(String)

    public var description: String {
        switch self {
        case .invalid(let id, let message):
            return "pose model spec \(id): \(message)"
        case .missingJoints(let id, let missing, let purpose):
            let names = missing.map(\.canonicalName).joined(separator: ", ")
            return "2D pose model \(id) does not predict \(names), which \(purpose) needs"
        case .notFound(let name, let available):
            return "unknown 2D pose model \(name); available: \(available.joined(separator: ", "))"
        case .notRunnableOnDevice(let id):
            return "2D pose model \(id) is a template or has no coreml section"
        }
    }
}

extension JointName {
    /// Snake-case names in `JointName` order; the canonical WholeBody23 layout shared with
    /// the server (`CANONICAL_KEYPOINTS` in core/pose_models/spec.py).
    public static let canonicalNames: [String] = [
        "nose", "left_eye", "right_eye", "left_ear", "right_ear",
        "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
        "left_wrist", "right_wrist", "left_hip", "right_hip",
        "left_knee", "right_knee", "left_ankle", "right_ankle",
        "left_big_toe", "left_small_toe", "left_heel",
        "right_big_toe", "right_small_toe", "right_heel",
    ]

    public var canonicalName: String { Self.canonicalNames[rawValue] }

    /// Joints the long-jump analysis reads (ankle, heel and both toes per foot).
    public static let longJumpJoints: [JointName] = [
        .leftAnkle, .rightAnkle,
        .leftBigToe, .leftSmallToe, .leftHeel,
        .rightBigToe, .rightSmallToe, .rightHeel,
    ]
}
