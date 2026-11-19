import Foundation

public enum SandMarkError: Error, Equatable, CustomStringConvertible {
    /// The track has none of the heel/toe joints that give the sand surface.
    case noFootJoints

    public var description: String { "track has no foot joints for the sand surface" }
}

/// sand_mark.py without the segmentation: the nearest-to-board mark in the sand from the
/// runner's silhouettes (any body part), searched from the sand landing over a short window.
public enum SandMarkFinder {
    /// FOOT_JOINTS_ON_SAND.
    public static let footJointsOnSand = [
        "left_big_toe", "left_small_toe", "left_heel", "right_big_toe", "right_small_toe", "right_heel",
    ]

    /// BODY_PART_OF_JOINT, in the Python dict's order (first matching suffix wins).
    public static let bodyPartOfJoint: [(suffix: String, part: String)] = [
        ("hip", "buttocks"), ("ankle", "foot"), ("heel", "foot"), ("big_toe", "foot"),
        ("small_toe", "foot"), ("wrist", "hand"), ("knee", "knee"), ("elbow", "elbow"),
        ("shoulder", "shoulder"),
    ]

    /// A silhouette contact: the best mark so far, (frame, (x, y)).
    public struct Contact: Sendable, Equatable {
        public var frame: Int
        public var point: SIMD2<Int>

        public init(frame: Int, point: SIMD2<Int>) {
            self.frame = frame
            self.point = point
        }
    }

    /// `board_side_contact`: (x, y) of the silhouette column nearest the board whose lowest pixel
    /// touches the sand (lowest y >= sandY - tolerance), in source-frame coordinates.
    public static func boardSideContact(
        mask runner: RunnerMask, sandY: Double, tolerance: Double, boardOnRight: Bool
    ) -> SIMD2<Int>? {
        let mask = runner.mask
        let threshold = sandY - tolerance
        var chosen: (column: Int, lowest: Int)?
        for x in 0..<mask.width {
            var lowest = -1
            var y = mask.height - 1
            while y >= 0 {
                if mask.data[y * mask.width + x] != 0 { lowest = y; break }
                y -= 1
            }
            if lowest < 0 { continue }
            // lowest_y >= sand_y - tolerance (int vs float64 in numpy)
            guard Double(lowest + runner.top) >= threshold else { continue }
            // The nearest touching column: the largest x toward a right board, the smallest else.
            if chosen == nil || boardOnRight { chosen = (x, lowest) }
        }
        guard let chosen else { return nil }
        return SIMD2(chosen.column + runner.left, chosen.lowest + runner.top)
    }

    /// `sand_surface_y`: the largest heel/toe y at the sand-landing frame.  Throws when the track
    /// has none of those joints (the Python's `np.nanmax([])` raises).
    public static func sandSurfaceY(track: PoseTrack, index: Int) throws -> Double {
        let values = footJointsOnSand.compactMap { name in
            track.jointIndex[name].map { track.jointsXY[index][$0].y }
        }
        guard !values.isEmpty else { throw SandMarkError.noFootJoints }
        return NP.nanMax(values)
    }

    /// `nearest_joint`: the confident joint nearest `point`, in the track's joint order (the first
    /// of equally near joints wins).
    public static func nearestJoint(
        track: PoseTrack, index: Int, point: SIMD2<Int>, minScore: Double
    ) -> String? {
        var best: String?
        var bestDistance = Double.infinity
        for (name, column) in track.jointIndex.sorted(by: { $0.value < $1.value }) {
            if track.jointScores[index][column] < minScore { continue }
            let xy = track.jointsXY[index][column]
            if !(xy.x.isFinite && xy.y.isFinite) { continue }
            let distance = hypot(xy.x - Double(point.x), xy.y - Double(point.y))
            if distance < bestDistance {
                best = name
                bestDistance = distance
            }
        }
        return best
    }

    /// `body_part_of`.
    public static func bodyPart(ofJoint joint: String?) -> String? {
        guard let joint, !joint.isEmpty else { return nil }
        for (suffix, part) in bodyPartOfJoint where joint.hasSuffix(suffix) { return part }
        return nil
    }

    /// `_nearest_contact_in_batch`: folds the batch's masks (nil = no runner found) into `best`.
    static func nearestContact(
        batch: [(frame: Int, box: SIMD4<Double>)],
        masks: [RunnerMask?],
        sandY: Double,
        rule: SandMarkRule,
        boardOnRight: Bool,
        best: Contact?
    ) -> Contact? {
        var best = best
        for (item, mask) in zip(batch, masks) {
            guard let mask else { continue }
            guard
                let contact = boardSideContact(
                    mask: mask, sandY: sandY, tolerance: rule.contactRatio * (item.box[3] - item.box[1]),
                    boardOnRight: boardOnRight)
            else { continue }
            let nearer = best == nil || (boardOnRight ? contact.x > best!.point.x : contact.x < best!.point.x)
            if nearer { best = Contact(frame: item.frame, point: contact) }
        }
        return best
    }

    /// `find_sand_mark`: the nearest-to-board mark from the sand landing to the end of `track`
    /// (already trimmed), at most `rule.maxWindowS` later; nil when there is none.  `runSide` is
    /// the side of the frame the athlete runs toward (the pit): running left, the board is on the
    /// right.  The server's result cache is not ported.
    public static func findSandMark(
        track: PoseTrack,
        sandLandingFrame: Int,
        runSide: Side,
        rule: SandMarkRule = SandMarkRule(),
        masks: RunnerMaskSource
    ) throws -> SandMark? {
        let indexByFrame = track.indexByFrame()
        guard let landIndex = indexByFrame[sandLandingFrame], let trackEnd = track.frames.last else { return nil }
        let window = PyRound.toInt(rule.maxWindowS * track.fps)
        let lastFrame = Swift.min(trackEnd, sandLandingFrame + window)
        let sandY = try sandSurfaceY(track: track, index: landIndex)
        let boardOnRight = runSide == .left

        var best: Contact?
        var searched = 0
        var batch: [(frame: Int, box: SIMD4<Double>)] = []
        let batchSize = Swift.max(1, rule.batchSize)

        func flush() throws {
            let found = try batch.map { try masks.runnerMask(frame: $0.frame, box: $0.box) }
            best = nearestContact(
                batch: batch, masks: found, sandY: sandY, rule: rule, boardOnRight: boardOnRight, best: best)
            searched += batch.count
            batch = []
        }

        if sandLandingFrame <= lastFrame {
            for frame in sandLandingFrame...lastFrame {
                guard let index = indexByFrame[frame] else { continue }
                let box = track.boxes[index]
                guard box.x.isFinite && box.y.isFinite && box.z.isFinite && box.w.isFinite else { continue }
                batch.append((frame, box))
                if batch.count >= batchSize { try flush() }
            }
        }
        if !batch.isEmpty { try flush() }

        guard let best else { return nil }
        let joint = nearestJoint(
            track: track, index: indexByFrame[best.frame]!, point: best.point, minScore: rule.minJointScore)
        return SandMark(
            frame: best.frame, imagePx: best.point, joint: joint, bodyPart: bodyPart(ofJoint: joint),
            framesSearched: searched)
    }
}
