/// Shared value types of the long-jump analysis.  Each mirrors a dataclass or tuple of
/// runner-analysis-pipeline core/longjump/ (named in its doc comment); field meanings follow the
/// Python docstrings.

/// "left" / "right": a foot, or the side of the frame the athlete runs toward (where the pit is;
/// detection.PIT_LEFT / PIT_RIGHT).
public enum Side: String, Sendable, Codable, CaseIterable {
    case left
    case right
}

/// detection.TrimResult: where the clip ends (athlete starts getting up in the sand).
public struct TrimResult: Sendable, Equatable {
    /// Exclusive end index of the jump clip in the full track.
    public var endIndex: Int
    /// [start, end) of the fast run-up segment, or nil when none was found.
    public var fastSegment: Range<Int>?
    public var referenceSpeed: Double?
    public var anchorIndex: Int?

    public init(endIndex: Int, fastSegment: Range<Int>?, referenceSpeed: Double? = nil, anchorIndex: Int? = nil) {
        self.endIndex = endIndex
        self.fastSegment = fastSegment
        self.referenceSpeed = referenceSpeed
        self.anchorIndex = anchorIndex
    }
}

/// detection.BoardContactSelection: the take-off (TD) choice and its evidence.
public struct BoardContactSelection: Sendable, Equatable {
    public var index: Int?
    /// e.g. "fixed_informative_speed_scale", "adaptive_slow_speed_scale" (the Python strings).
    public var mode: String
    public var referenceSpeed: Double?
    public var precontactBelowFixedFraction: Double?

    public init(index: Int?, mode: String, referenceSpeed: Double? = nil, precontactBelowFixedFraction: Double? = nil) {
        self.index = index
        self.mode = mode
        self.referenceSpeed = referenceSpeed
        self.precontactBelowFixedFraction = precontactBelowFixedFraction
    }
}

/// Take-off position against the board: "BEFORE_BOARD" / "ON_BOARD" / "OVER_LINE".
public enum TakeoffPosition: String, Sendable, Codable {
    case beforeBoard = "BEFORE_BOARD"
    case onBoard = "ON_BOARD"
    case overLine = "OVER_LINE"
}

/// detection.BoardContactAssessment: take-off stance timing and its position against the board.
public struct BoardContactAssessment: Sendable, Equatable {
    public var footSide: Side?
    public var boardContactIndex: Int?
    public var toeOffIndex: Int?
    public var minToeClearancePx: Double?
    public var clearanceFrameIndex: Int?
    public var toeOverLine: Bool?
    public var takeoffPosition: TakeoffPosition?
    public var minBoardDistancePx: Double?

    public init(
        footSide: Side?,
        boardContactIndex: Int?,
        toeOffIndex: Int?,
        minToeClearancePx: Double? = nil,
        clearanceFrameIndex: Int? = nil,
        toeOverLine: Bool? = nil,
        takeoffPosition: TakeoffPosition? = nil,
        minBoardDistancePx: Double? = nil
    ) {
        self.footSide = footSide
        self.boardContactIndex = boardContactIndex
        self.toeOffIndex = toeOffIndex
        self.minToeClearancePx = minToeClearancePx
        self.clearanceFrameIndex = clearanceFrameIndex
        self.toeOverLine = toeOverLine
        self.takeoffPosition = takeoffPosition
        self.minBoardDistancePx = minBoardDistancePx
    }
}

/// detection.JumpEvents: video frame numbers of the detected events (nil when not found).
public struct JumpEvents: Sendable, Equatable {
    public var flightStart: Int
    public var flightEnd: Int
    public var apex: Int
    public var boardContact: Int?
    public var toeOff: Int?
    public var sandLanding: Int?
    public var takeoffAssessment: BoardContactAssessment?
    /// Reasons to check the landing by hand (detection.review_sand_landing).
    public var sandLandingReview: [String]

    public init(
        flightStart: Int,
        flightEnd: Int,
        apex: Int,
        boardContact: Int?,
        toeOff: Int?,
        sandLanding: Int?,
        takeoffAssessment: BoardContactAssessment? = nil,
        sandLandingReview: [String] = []
    ) {
        self.flightStart = flightStart
        self.flightEnd = flightEnd
        self.apex = apex
        self.boardContact = boardContact
        self.toeOff = toeOff
        self.sandLanding = sandLanding
        self.takeoffAssessment = takeoffAssessment
        self.sandLandingReview = sandLandingReview
    }
}

/// detection.TakeoffLine: the board edge nearest the pit, as its endpoints at the board's
/// smallest and largest y (image pixels).
public struct TakeoffLine: Sendable, Equatable {
    public var top: SIMD2<Double>
    public var bottom: SIMD2<Double>

    public init(top: SIMD2<Double>, bottom: SIMD2<Double>) {
        self.top = top
        self.bottom = bottom
    }

    /// x of the line at image row y (same operation order as the Python `x_at`).
    public func x(atY y: Double) -> Double {
        if bottom.y == top.y { return top.x }  // single-row board mask
        return top.x + (y - top.y) * (bottom.x - top.x) / (bottom.y - top.y)
    }
}

/// detection.BoardCandidate: one white blob scored as a take-off board.
public struct BoardCandidate: Sendable, Equatable {
    public var ringRed: Double
    public var area: Int
    public var label: Int
    /// x, y, width, height (OpenCV connected-component stats).
    public var bbox: [Int]

    public init(ringRed: Double, area: Int, label: Int, bbox: [Int]) {
        self.ringRed = ringRed
        self.area = area
        self.label = label
        self.bbox = bbox
    }
}

/// detection.BoardDetection: the chosen board mask (nil when no board) and every candidate.
public struct BoardDetection: Sendable, Equatable {
    public var mask: BinaryMask?
    public var candidates: [BoardCandidate]

    public init(mask: BinaryMask?, candidates: [BoardCandidate]) {
        self.mask = mask
        self.candidates = candidates
    }
}

/// detection.BoardView: a detected board, its mask and (when fitted) its take-off line.
public struct BoardView: Sendable, Equatable {
    public var mask: BinaryMask
    public var line: TakeoffLine?

    public init(mask: BinaryMask, line: TakeoffLine?) {
        self.mask = mask
        self.line = line
    }
}

/// pit_homography.PitCalibration: 4-6 image points on the pit and their world coordinates in
/// metres (X along the pit, Y across it).
public struct PitCalibration: Sendable, Equatable {
    public static let defaultBoardOffsetM = 2.0

    public var imagePoints: [SIMD2<Double>]
    public var worldPoints: [SIMD2<Double>]
    /// Take-off line -> pit edge (metres).
    public var boardOffsetM: Double

    public init(imagePoints: [SIMD2<Double>], worldPoints: [SIMD2<Double>], boardOffsetM: Double = PitCalibration.defaultBoardOffsetM) {
        self.imagePoints = imagePoints
        self.worldPoints = worldPoints
        self.boardOffsetM = boardOffsetM
    }
}

/// sand_mark.SandMark: the nearest mark in the sand, from the runner's segmentation silhouette.
public struct SandMark: Sendable, Equatable {
    /// Source video frame where the nearest mark was seen.
    public var frame: Int
    /// (x, y) in the source frame.
    public var imagePx: SIMD2<Int>
    /// Nearest confident joint (naming only).
    public var joint: String?
    public var bodyPart: String?
    public var framesSearched: Int

    public init(frame: Int, imagePx: SIMD2<Int>, joint: String?, bodyPart: String?, framesSearched: Int) {
        self.frame = frame
        self.imagePx = imagePx
        self.joint = joint
        self.bodyPart = bodyPart
        self.framesSearched = framesSearched
    }
}

/// result_output.STATUS_*: the attempt's status in the result document.
public enum LongJumpStatus: String, Sendable, Codable {
    case jump
    /// Jumped, but the take-off toe was past the take-off line (board detected).
    case foul
    case noTakeoff = "no_takeoff"
    case trackingLost = "tracking_lost"
}
