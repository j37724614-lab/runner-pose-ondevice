import Foundation

public struct AnalysisGaitResult: Sendable, Equatable {
    public var legIdentityFrames: [AnalysisLegIdentityFrame]
    public var contactEvents: [AnalysisContactEvent]
    public var steps: AnalysisStepsArtifactDocument
    public var durationSeconds: Double
    public var warnings: [String]

    public init(
        legIdentityFrames: [AnalysisLegIdentityFrame],
        contactEvents: [AnalysisContactEvent],
        steps: AnalysisStepsArtifactDocument,
        durationSeconds: Double,
        warnings: [String] = []
    ) {
        self.legIdentityFrames = legIdentityFrames
        self.contactEvents = contactEvents
        self.steps = steps
        self.durationSeconds = durationSeconds
        self.warnings = warnings
    }
}

/// On-device port of the Server's runner gait path: temporal leg identity,
/// six-Hz foot trajectories, lower-ankle touchdown peaks, foot contact point
/// selection, calibration projection, step length, stride length and cadence.
public struct ServerAlignedGaitProcessor: AnalysisGaitProcessing {
    public init() {}

    public func process(
        pose2D: Analysis2DResult,
        kinematics: AnalysisKinematicsResult?,
        request: AnalysisRequest
    ) throws -> AnalysisGaitResult {
        let startedAt = Date()
        var identity: [AnalysisLegIdentityFrame] = []
        var contacts: [AnalysisContactEvent] = []
        var steps: [AnalysisStepSample] = []
        var cadenceIntervals: [Double] = []
        var warnings: [String] = []

        for camera in request.cameras.sorted(by: { $0.cameraIndex < $1.cameraIndex }) {
            let input = pose2D.frames
                .filter {
                    $0.cameraIndex == camera.cameraIndex && $0.valid
                        && $0.joints.count >= AnalysisCoordinateSystem.wholeBody23JointOrder.count
                }
                .sorted { $0.sourceFrame < $1.sourceFrame }
            guard input.count >= 5 else { continue }
            let corrected = Self.correctLegIdentity(input)
            identity.append(contentsOf: corrected.identity)
            let fps = camera.video.fps > 0 ? camera.video.fps : 60
            let geometry = try CameraGeometry(
                calibration: camera.calibration,
                laneWidthM: request.kinematicsPolicy.laneWidthM
            )
            var cameraResult = Self.analyzeCamera(
                frames: corrected.frames,
                fps: fps,
                geometry: geometry,
                kinematics: kinematics
            )
            let contactOffset = contacts.count
            for index in cameraResult.contacts.indices {
                cameraResult.contacts[index].eventIndex += contactOffset
            }
            let stepOffset = steps.count
            for index in cameraResult.steps.indices {
                cameraResult.steps[index].stepIndex += stepOffset
            }
            contacts.append(contentsOf: cameraResult.contacts)
            steps.append(contentsOf: cameraResult.steps)
            cadenceIntervals.append(contentsOf: cameraResult.cadenceIntervals)
        }

        if contacts.isEmpty {
            warnings.append("No reliable Local touchdown peaks were detected.")
        }
        if !steps.isEmpty && steps.allSatisfy({ $0.stepLengthM == nil }) {
            warnings.append("Step timing was detected, but step length needs valid camera calibration.")
        }
        let stepLengths = steps.compactMap(\.stepLengthM)
        let strideLengths = steps.compactMap(\.strideLengthM)
        let cadence = cadenceIntervals.isEmpty
            ? nil
            : 60 / (cadenceIntervals.reduce(0, +) / Double(cadenceIntervals.count))
        return AnalysisGaitResult(
            legIdentityFrames: identity,
            contactEvents: contacts,
            steps: AnalysisStepsArtifactDocument(
                averageStepLengthM: Self.mean(stepLengths),
                averageStrideLengthM: Self.mean(strideLengths),
                averageCadenceSPM: cadence,
                steps: steps
            ),
            durationSeconds: Date().timeIntervalSince(startedAt),
            warnings: warnings
        )
    }
}

private extension ServerAlignedGaitProcessor {
    enum JointIndex {
        static let leftHip = 11, rightHip = 12
        static let leftKnee = 13, rightKnee = 14
        static let leftAnkle = 15, rightAnkle = 16
        static let leftBigToe = 17, leftSmallToe = 18, leftHeel = 19
        static let rightBigToe = 20, rightSmallToe = 21, rightHeel = 22
        static let sidePairs = [
            (leftHip, rightHip), (leftKnee, rightKnee), (leftAnkle, rightAnkle),
            (leftBigToe, rightBigToe), (leftSmallToe, rightSmallToe),
            (leftHeel, rightHeel),
        ]
    }

    struct CorrectedFrames {
        var frames: [Pose2DFrame]
        var identity: [AnalysisLegIdentityFrame]
    }

    struct Trajectory {
        var rawX: [Double]
        var rawY: [Double]
        var smoothX: [Double]
        var smoothY: [Double]
        var score: [Double]
    }

    struct Candidate {
        var frameIndex: Int
        var foot: AnalysisFoot
        var prominence: Double
        var source: String
    }

    struct CameraGaitResult {
        var contacts: [AnalysisContactEvent]
        var steps: [AnalysisStepSample]
        var cadenceIntervals: [Double]
    }

    struct SelectedContact {
        var point: AnalysisPoint
        var joint: AnalysisContactJoint
        var eventType: AnalysisContactEventType
        var confidence: Double
    }

    static func correctLegIdentity(_ frames: [Pose2DFrame]) -> CorrectedFrames {
        var corrected: [Pose2DFrame] = []
        var identity: [AnalysisLegIdentityFrame] = []
        corrected.reserveCapacity(frames.count)
        identity.reserveCapacity(frames.count)
        var reference: [Pose2DJoint]?

        for frame in frames {
            var output = frame
            var swapped = false
            var confidence = 0.5
            if output.joints.count >= AnalysisCoordinateSystem.wholeBody23JointOrder.count,
               let previous = reference {
                let noSwap = legCost(current: output.joints, reference: previous, swapped: false)
                let swap = legCost(current: output.joints, reference: previous, swapped: true)
                if noSwap.isFinite, swap.isFinite {
                    swapped = swap < noSwap * 0.75
                    confidence = min(1, abs(noSwap - swap) / max(1, max(noSwap, swap)))
                }
                if swapped {
                    for pair in JointIndex.sidePairs {
                        output.joints.swapAt(pair.0, pair.1)
                    }
                }
            }
            if output.joints.count >= AnalysisCoordinateSystem.wholeBody23JointOrder.count {
                reference = output.joints
            }
            corrected.append(output)
            identity.append(AnalysisLegIdentityFrame(
                cameraIndex: output.cameraIndex,
                sourceFrame: output.sourceFrame,
                timestampSeconds: output.timestampSeconds,
                leftSource: swapped ? .detectedRight : .detectedLeft,
                rightSource: swapped ? .detectedLeft : .detectedRight,
                swapped: swapped,
                confidence: confidence,
                reason: swapped ? .temporalDP : .none
            ))
        }
        return CorrectedFrames(frames: corrected, identity: identity)
    }

    static func legCost(
        current: [Pose2DJoint],
        reference: [Pose2DJoint],
        swapped: Bool
    ) -> Double {
        let left = [JointIndex.leftHip, JointIndex.leftKnee, JointIndex.leftAnkle]
        let right = [JointIndex.rightHip, JointIndex.rightKnee, JointIndex.rightAnkle]
        var cost = 0.0
        var count = 0
        for (leftIndex, rightIndex) in zip(left, right) {
            let currentLeft = current[swapped ? rightIndex : leftIndex]
            let currentRight = current[swapped ? leftIndex : rightIndex]
            let referenceLeft = reference[leftIndex]
            let referenceRight = reference[rightIndex]
            for pair in [(currentLeft, referenceLeft), (currentRight, referenceRight)]
            where pair.0.score >= 0.15 && pair.1.score >= 0.15 {
                cost += hypot(pair.0.x - pair.1.x, pair.0.y - pair.1.y)
                count += 1
            }
        }
        return count >= 4 ? cost / Double(count) : .infinity
    }

    static func analyzeCamera(
        frames: [Pose2DFrame],
        fps: Double,
        geometry: CameraGeometry,
        kinematics: AnalysisKinematicsResult?
    ) -> CameraGaitResult {
        let footJointIndexes = [
            JointIndex.leftAnkle, JointIndex.rightAnkle,
            JointIndex.leftBigToe, JointIndex.leftSmallToe, JointIndex.leftHeel,
            JointIndex.rightBigToe, JointIndex.rightSmallToe, JointIndex.rightHeel,
        ]
        let trajectories = Dictionary(uniqueKeysWithValues: footJointIndexes.map {
            ($0, trajectory(frames, joint: $0, fps: fps))
        })
        let leftAnkle = trajectories[JointIndex.leftAnkle]!
        let rightAnkle = trajectories[JointIndex.rightAnkle]!
        let rawLowerY = zip(leftAnkle.rawY, rightAnkle.rawY).map { max($0.0, $0.1) }
        let smoothLowerY = zip(leftAnkle.smoothY, rightAnkle.smoothY).map { max($0.0, $0.1) }
        let peakDistance = max(3, Int(fps / 8))
        let minStepFrames = max(4, Int(fps / 4.5))
        let minimumGap = max(3, minStepFrames / 2)
        let prominence = max(interquartileRange(smoothLowerY) * 0.20, 1.5)
        var candidates = peakCandidates(
            signal: smoothLowerY,
            threshold: prominence,
            minimumGap: minimumGap,
            peakWindow: peakDistance,
            source: "smooth"
        )
        candidates = rescueRawPeaks(
            candidates,
            rawSignal: rawLowerY,
            threshold: max(interquartileRange(rawLowerY) * 0.20, 1.5),
            peakDistance: peakDistance,
            minStepFrames: minStepFrames,
            minimumGap: minimumGap
        )
        candidates = deduplicate(
            candidates,
            left: leftAnkle,
            right: rightAnkle,
            geometry: geometry,
            fps: fps,
            minimumGap: minimumGap
        )
        labelAlternatingFeet(&candidates, left: leftAnkle, right: rightAnkle, radius: max(1, peakDistance / 3))

        var contacts: [AnalysisContactEvent] = []
        var touchdownContacts: [Int: SelectedContact] = [:]
        var toeOffTime: [Int: Double] = [:]
        for (index, candidate) in candidates.enumerated() {
            let frame = frames[candidate.frameIndex]
            let selected = selectContact(
                frame: frame,
                frameIndex: candidate.frameIndex,
                foot: candidate.foot,
                trajectories: trajectories
            )
            touchdownContacts[index] = selected
            contacts.append(AnalysisContactEvent(
                eventIndex: contacts.count,
                eventType: selected.eventType,
                foot: candidate.foot,
                cameraIndex: frame.cameraIndex,
                sourceFrame: frame.sourceFrame,
                timestampSeconds: frame.timestampSeconds,
                contactJoint: selected.joint,
                imagePoint: selected.point,
                worldPointM: geometry.gaitWorldPoint(selected.point),
                confidence: clamp01(min(
                    selected.confidence,
                    frames[candidate.frameIndex].bboxExtrapolated ? 0.7 : 1
                )),
                reason: "lower_ankle_peak_6hz_\(candidate.source)"
            ))

            let stop = index + 1 < candidates.count
                ? candidates[index + 1].frameIndex
                : min(frames.count - 1, candidate.frameIndex + Int(fps * 0.30))
            if let toeOff = findToeOff(
                touchdown: candidate,
                stop: stop,
                left: leftAnkle,
                right: rightAnkle,
                fps: fps,
                prominence: prominence
            ) {
                let toeFrame = frames[toeOff]
                let toeContact = selectToeOffContact(
                    frame: toeFrame,
                    frameIndex: toeOff,
                    foot: candidate.foot,
                    trajectories: trajectories
                )
                toeOffTime[index] = toeFrame.timestampSeconds
                contacts.append(AnalysisContactEvent(
                    eventIndex: contacts.count,
                    eventType: .toeOff,
                    foot: candidate.foot,
                    cameraIndex: toeFrame.cameraIndex,
                    sourceFrame: toeFrame.sourceFrame,
                    timestampSeconds: toeFrame.timestampSeconds,
                    contactJoint: toeContact.joint,
                    imagePoint: toeContact.point,
                    worldPointM: geometry.gaitWorldPoint(toeContact.point),
                    confidence: clamp01(toeContact.confidence),
                    reason: "same_foot_vertical_departure"
                ))
            }
        }

        contacts.sort {
            if $0.sourceFrame == $1.sourceFrame { return $0.eventType.rawValue < $1.eventType.rawValue }
            return $0.sourceFrame < $1.sourceFrame
        }
        for index in contacts.indices { contacts[index].eventIndex = index }

        var steps: [AnalysisStepSample] = []
        var cadenceIntervals: [Double] = []
        var previousWorld: AnalysisPoint?
        var previousTime: Double?
        var previousByFoot: [AnalysisFoot: AnalysisPoint] = [:]
        for (index, candidate) in candidates.enumerated() {
            guard let contact = touchdownContacts[index] else { continue }
            let frame = frames[candidate.frameIndex]
            let world = geometry.gaitWorldPoint(contact.point)
            let stepLength = Self.distanceAlongTrack(world, previousWorld)
            let strideLength = Self.distanceAlongTrack(world, previousByFoot[candidate.foot])
            if let previousTime {
                let interval = frame.timestampSeconds - previousTime
                if interval > 0 { cadenceIntervals.append(interval) }
            }
            let speed = nearestSpeed(
                cameraIndex: frame.cameraIndex,
                sourceFrame: frame.sourceFrame,
                kinematics: kinematics
            )
            steps.append(AnalysisStepSample(
                stepIndex: index + 1,
                eventType: .step,
                foot: candidate.foot,
                cameraIndex: frame.cameraIndex,
                sourceFrame: frame.sourceFrame,
                timestampSeconds: frame.timestampSeconds,
                worldXM: world?.x,
                worldYM: world?.y,
                stepLengthM: stepLength,
                strideLengthM: strideLength,
                contactTimeSeconds: toeOffTime[index].map { max(0, $0 - frame.timestampSeconds) },
                speedMPS: speed,
                confidence: clamp01(min(
                    contact.confidence,
                    candidate.prominence / max(prominence, 0.001)
                ))
            ))
            previousWorld = world
            if let world { previousByFoot[candidate.foot] = world }
            previousTime = frame.timestampSeconds
        }
        return CameraGaitResult(
            contacts: contacts,
            steps: steps,
            cadenceIntervals: cadenceIntervals
        )
    }

    static func trajectory(_ frames: [Pose2DFrame], joint: Int, fps: Double) -> Trajectory {
        var xs: [Double?] = []
        var ys: [Double?] = []
        var scores: [Double] = []
        for frame in frames {
            guard joint < frame.joints.count else {
                xs.append(nil); ys.append(nil); scores.append(0)
                continue
            }
            let value = frame.joints[joint]
            scores.append(value.score)
            if value.score >= 0.15, value.x.isFinite, value.y.isFinite {
                xs.append(value.x); ys.append(value.y)
            } else {
                xs.append(nil); ys.append(nil)
            }
        }
        let filledX = interpolate(xs)
        let filledY = interpolate(ys)
        return Trajectory(
            rawX: filledX,
            rawY: filledY,
            smoothX: lowpassZeroPhase(filledX, fps: fps, cutoff: 6),
            smoothY: lowpassZeroPhase(filledY, fps: fps, cutoff: 6),
            score: scores
        )
    }

    static func peakCandidates(
        signal: [Double],
        threshold: Double,
        minimumGap: Int,
        peakWindow: Int,
        source: String
    ) -> [Candidate] {
        guard signal.count >= 3 else { return [] }
        var peaks: [Candidate] = []
        for index in 1..<(signal.count - 1)
        where signal[index] >= signal[index - 1] && signal[index] > signal[index + 1] {
            let value = peakProminence(signal, at: index, window: max(2, peakWindow * 2))
            guard value >= threshold else { continue }
            let candidate = Candidate(
                frameIndex: index,
                foot: .unknown,
                prominence: value,
                source: source
            )
            if let previous = peaks.last, index - previous.frameIndex < minimumGap {
                if value > previous.prominence { peaks[peaks.count - 1] = candidate }
            } else {
                peaks.append(candidate)
            }
        }
        return peaks
    }

    static func rescueRawPeaks(
        _ smooth: [Candidate],
        rawSignal: [Double],
        threshold: Double,
        peakDistance: Int,
        minStepFrames: Int,
        minimumGap: Int
    ) -> [Candidate] {
        guard smooth.count >= 2 else { return smooth }
        let raw = peakCandidates(
            signal: rawSignal,
            threshold: threshold,
            minimumGap: peakDistance,
            peakWindow: peakDistance,
            source: "raw_rescue"
        )
        let rescueGap = max(minStepFrames + peakDistance, Int((Double(minStepFrames) * 1.8).rounded()))
        var output: [Candidate] = []
        for pairIndex in 1..<smooth.count {
            let previous = smooth[pairIndex - 1]
            let following = smooth[pairIndex]
            output.append(previous)
            guard following.frameIndex - previous.frameIndex >= rescueGap else { continue }
            let candidates = raw.filter {
                $0.frameIndex - previous.frameIndex >= minimumGap
                    && following.frameIndex - $0.frameIndex >= minimumGap
            }
            if let best = candidates.max(by: { $0.prominence < $1.prominence }) {
                output.append(best)
            }
        }
        if let last = smooth.last { output.append(last) }
        return output.sorted { $0.frameIndex < $1.frameIndex }
    }

    static func deduplicate(
        _ candidates: [Candidate],
        left: Trajectory,
        right: Trajectory,
        geometry: CameraGeometry,
        fps: Double,
        minimumGap: Int
    ) -> [Candidate] {
        var result: [Candidate] = []
        for candidate in candidates {
            guard let previous = result.last else {
                result.append(candidate); continue
            }
            let currentPoint = lowerAnklePoint(candidate.frameIndex, left: left, right: right)
            let previousPoint = lowerAnklePoint(previous.frameIndex, left: left, right: right)
            let currentWorld = geometry.gaitWorldPoint(currentPoint)
            let previousWorld = geometry.gaitWorldPoint(previousPoint)
            let movement = distanceAlongTrack(currentWorld, previousWorld)
                ?? hypot(currentPoint.x - previousPoint.x, currentPoint.y - previousPoint.y)
            let threshold = currentWorld != nil && previousWorld != nil ? 0.60 : 20.0
            let gap = candidate.frameIndex - previous.frameIndex
            let duplicate = movement < threshold || (gap < max(minimumGap, Int(fps / 5)) && movement < threshold)
            if duplicate {
                if candidate.prominence > previous.prominence { result[result.count - 1] = candidate }
            } else {
                result.append(candidate)
            }
        }
        return result
    }

    static func labelAlternatingFeet(
        _ candidates: inout [Candidate],
        left: Trajectory,
        right: Trajectory,
        radius: Int
    ) {
        guard !candidates.isEmpty else { return }
        let anchor = candidates[0].frameIndex
        let lower = max(0, anchor - radius)
        let upper = min(left.smoothY.count - 1, anchor + radius)
        var leftVotes = 0, rightVotes = 0
        for index in lower...upper {
            if left.smoothY[index] > right.smoothY[index] { leftVotes += 1 } else { rightVotes += 1 }
        }
        candidates[0].foot = leftVotes > rightVotes ? .left : .right
        if candidates.count > 1 {
            for index in 1..<candidates.count {
                candidates[index].foot = candidates[index - 1].foot == .left ? .right : .left
            }
        }
    }

    static func selectContact(
        frame: Pose2DFrame,
        frameIndex: Int,
        foot: AnalysisFoot,
        trajectories: [Int: Trajectory]
    ) -> SelectedContact {
        let indices: [(Int, AnalysisContactJoint, AnalysisContactEventType)]
        let ankleIndex: Int
        switch foot {
        case .left:
            ankleIndex = JointIndex.leftAnkle
            indices = [
                (JointIndex.leftHeel, .heel, .heelStrike),
                (JointIndex.leftBigToe, .bigToe, .toeStrike),
                (JointIndex.leftSmallToe, .smallToe, .toeStrike),
            ]
        default:
            ankleIndex = JointIndex.rightAnkle
            indices = [
                (JointIndex.rightHeel, .heel, .heelStrike),
                (JointIndex.rightBigToe, .bigToe, .toeStrike),
                (JointIndex.rightSmallToe, .smallToe, .toeStrike),
            ]
        }
        let ankle = frame.joints[ankleIndex]
        let anklePoint = smoothedPoint(
            joint: ankleIndex,
            frameIndex: frameIndex,
            fallback: ankle,
            trajectories: trajectories
        )
        let height = frame.bbox.map { $0.y2 - $0.y1 } ?? 100
        let attachmentLimit = max(12, height * 0.18)
        let verticalTolerance = max(5, height * 0.03)
        for item in indices {
            let joint = frame.joints[item.0]
            let point = smoothedPoint(
                joint: item.0,
                frameIndex: frameIndex,
                fallback: joint,
                trajectories: trajectories
            )
            guard joint.score >= 0.50,
                  hypot(point.x - anklePoint.x, point.y - anklePoint.y) <= attachmentLimit,
                  point.y >= anklePoint.y - verticalTolerance else { continue }
            return SelectedContact(
                point: point,
                joint: item.1,
                eventType: item.2,
                confidence: joint.score
            )
        }
        return SelectedContact(
            point: anklePoint,
            joint: .ankle,
            eventType: .touchdown,
            confidence: ankle.score
        )
    }

    static func selectToeOffContact(
        frame: Pose2DFrame,
        frameIndex: Int,
        foot: AnalysisFoot,
        trajectories: [Int: Trajectory]
    ) -> SelectedContact {
        let toeIndex = foot == .left ? JointIndex.leftBigToe : JointIndex.rightBigToe
        let ankleIndex = foot == .left ? JointIndex.leftAnkle : JointIndex.rightAnkle
        let toe = frame.joints[toeIndex]
        let ankle = frame.joints[ankleIndex]
        if toe.score >= 0.50 {
            return SelectedContact(
                point: smoothedPoint(
                    joint: toeIndex,
                    frameIndex: frameIndex,
                    fallback: toe,
                    trajectories: trajectories
                ),
                joint: .bigToe,
                eventType: .toeOff,
                confidence: toe.score
            )
        }
        return SelectedContact(
            point: smoothedPoint(
                joint: ankleIndex,
                frameIndex: frameIndex,
                fallback: ankle,
                trajectories: trajectories
            ),
            joint: .ankle,
            eventType: .toeOff,
            confidence: ankle.score
        )
    }

    static func findToeOff(
        touchdown: Candidate,
        stop: Int,
        left: Trajectory,
        right: Trajectory,
        fps: Double,
        prominence: Double
    ) -> Int? {
        let values = touchdown.foot == .left ? left.smoothY : right.smoothY
        let start = min(values.count - 1, touchdown.frameIndex + max(2, Int(fps * 0.04)))
        let upper = min(values.count - 1, stop)
        guard start < upper else { return nil }
        let departure = max(2, prominence * 0.5)
        let groundY = values[touchdown.frameIndex]
        for index in start..<upper where values[index] <= groundY - departure {
            let next = min(index + 1, values.count - 1)
            if values[next] <= groundY - departure { return index }
        }
        return nil
    }

    static func lowerAnklePoint(_ index: Int, left: Trajectory, right: Trajectory) -> AnalysisPoint {
        if left.smoothY[index] > right.smoothY[index] {
            return AnalysisPoint(x: left.smoothX[index], y: left.smoothY[index])
        }
        return AnalysisPoint(x: right.smoothX[index], y: right.smoothY[index])
    }

    static func smoothedPoint(
        joint: Int,
        frameIndex: Int,
        fallback: Pose2DJoint,
        trajectories: [Int: Trajectory]
    ) -> AnalysisPoint {
        guard let trajectory = trajectories[joint], frameIndex < trajectory.smoothX.count else {
            return AnalysisPoint(x: fallback.x, y: fallback.y)
        }
        return AnalysisPoint(
            x: trajectory.smoothX[frameIndex],
            y: trajectory.smoothY[frameIndex]
        )
    }

    static func nearestSpeed(
        cameraIndex: Int,
        sourceFrame: Int,
        kinematics: AnalysisKinematicsResult?
    ) -> Double? {
        guard let frames = kinematics?.frames else { return nil }
        return frames
            .filter { $0.cameraIndex == cameraIndex }
            .min(by: { abs($0.sourceFrame - sourceFrame) < abs($1.sourceFrame - sourceFrame) })?
            .speedMPS
    }

    static func distanceAlongTrack(_ lhs: AnalysisPoint?, _ rhs: AnalysisPoint?) -> Double? {
        guard let lhs, let rhs else { return nil }
        return abs(lhs.x - rhs.x)
    }

    static func interpolate(_ values: [Double?]) -> [Double] {
        let valid = values.indices.filter { values[$0] != nil }
        guard let first = valid.first, let last = valid.last else {
            return Array(repeating: 0, count: values.count)
        }
        var output = Array(repeating: values[first]!, count: values.count)
        for index in first...last where values[index] != nil { output[index] = values[index]! }
        for pair in 1..<valid.count {
            let left = valid[pair - 1], right = valid[pair]
            guard right > left + 1 else { continue }
            for index in (left + 1)..<right {
                let ratio = Double(index - left) / Double(right - left)
                output[index] = output[left] + (output[right] - output[left]) * ratio
            }
        }
        if last + 1 < output.count {
            for index in (last + 1)..<output.count { output[index] = output[last] }
        }
        return output
    }

    static func lowpassZeroPhase(_ input: [Double], fps: Double, cutoff: Double) -> [Double] {
        guard input.count >= 15, fps > 0, cutoff > 0, cutoff < fps / 2 else { return input }
        let k = tan(.pi * cutoff / fps)
        let norm = 1 / (1 + sqrt(2) * k + k * k)
        let b = [k * k * norm, 2 * k * k * norm, k * k * norm]
        let a = [1.0, 2 * (k * k - 1) * norm, (1 - sqrt(2) * k + k * k) * norm]
        let edge = min(9, input.count - 1)
        let left = (1...edge).reversed().map { 2 * input[0] - input[$0] }
        let right = (1...edge).map { 2 * input[input.count - 1] - input[input.count - 1 - $0] }
        let extended = left + input + right
        let forward = filter(extended, b: b, a: a)
        let backward = Array(filter(Array(forward.reversed()), b: b, a: a).reversed())
        return Array(backward.dropFirst(edge).prefix(input.count))
    }

    static func filter(_ input: [Double], b: [Double], a: [Double]) -> [Double] {
        guard let first = input.first else { return [] }
        var z0 = (1 - b[0]) * first
        var z1 = (b[2] - a[2]) * first
        var output: [Double] = []
        for value in input {
            let result = b[0] * value + z0
            let nextZ0 = b[1] * value - a[1] * result + z1
            z1 = b[2] * value - a[2] * result
            z0 = nextZ0
            output.append(result)
        }
        return output
    }

    static func peakProminence(_ signal: [Double], at index: Int, window: Int) -> Double {
        let leftStart = max(0, index - window)
        let rightEnd = min(signal.count - 1, index + window)
        let leftMinimum = signal[leftStart..<index].min() ?? signal[index]
        let rightMinimum = signal[(index + 1)...rightEnd].min() ?? signal[index]
        return signal[index] - max(leftMinimum, rightMinimum)
    }

    static func interquartileRange(_ values: [Double]) -> Double {
        percentile(values, 0.75) - percentile(values, 0.25)
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        let ratio = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * ratio
    }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
