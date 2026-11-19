/// Thresholds of the long-jump analysis: the Python rule dataclasses with the same defaults.
/// Change them only together with the server (they were tuned on the 27-jump GT).

/// detection.FlightRule: airborne = local ground y2 - y2 > rise_ratio x bbox height, for at
/// least min_flight_s.
public struct FlightRule: Sendable, Equatable {
    public var minFlightS = 0.3
    public var riseRatio = 0.15
    public var groundReachS = 1.5
    public init() {}
}

/// detection.SandLandingRule: landing = the frame after the largest drop in downward y2 velocity.
public struct SandLandingRule: Sendable, Equatable {
    public var smoothing = 5
    public var decelerationSmoothing = 3
    public var descentSearchAfterFlight = 10
    public var searchBeforeFlightEnd = 2
    public var stillSpeedHeightsPerS = 0.2
    public var stillFrames = 3
    public var maxAfterFlightS = 0.25
    public init() {}
}

/// detection.BoardContactRule: take-off timing from the normalised toe-centre speed.
public struct BoardContactRule: Sendable, Equatable {
    public var maxStillSpeedPerS = 3.55
    public var toeOffMaxStillSpeedPerS = 1.15
    public var maxBridgeFrames = 1
    public var speedSmoothing = 3
    public var boardDistanceRatio = 0.03
    public var maxGapBeforeFlight = 6
    public var maxFramesBack = 25
    public var adaptiveTdRatio = 0.75
    public var adaptiveTdMaxDisagreementFrames = 2
    public var adaptiveValleyLookbackFrames = 14
    public var adaptiveReferenceLookbackFrames = 12
    public var adaptiveReferencePercentile = 80.0
    public var adaptiveFloorSamples = 3
    public var fixedTdMinReferenceRatio = 1.10
    public var fixedTdMaxPrecontactBelowFraction = 0.50
    public init() {}
}

/// detection.TrimRule: cut the clip when the athlete starts getting up after sitting in the sand.
public struct TrimRule: Sendable, Equatable {
    public var coarsePercentile = 95.0
    public var fastRatio = 0.5
    public var slowRatio = 0.35
    public var slowHold = 10
    public var settleWindow = 60
    public var riseRatio = 1.2
    public var riseHold = 5
    public var speedSmoothing = 9
    public var heightSmoothing = 5
    public init() {}
}

/// detection.BoardRule: white blob (low S, high V) whose surrounding ring is mostly red runway.
public struct BoardRule: Sendable, Equatable {
    public var ringPx = 6
    public var minArea = 150
    public var maxArea = 5000
    public var minRingRed = 0.5
    public init() {}
}

/// sand_mark.SandMarkRule (the segmentation settings are the server's; the phone's segmenter
/// documents its own).
public struct SandMarkRule: Sendable, Equatable {
    /// Touching: lowest silhouette y >= sand y - ratio x bbox height.
    public var contactRatio = 0.03
    /// Joints used only to name the body part of the mark.
    public var minJointScore = 0.3
    public var imageSize = 1280
    public var personConfidence = 0.2
    /// ROI = tracked bbox + this many bbox sizes on every side.
    public var bboxMarginRatio = 1.0
    public var minRunnerIou = 0.1
    /// Search at most this long after the sand landing.
    public var maxWindowS = 0.5
    public var batchSize = 1
    public init() {}
}
