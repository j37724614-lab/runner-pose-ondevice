import XCTest
@testable import LongJumpKit

/// Replays the recorded sand_mark.py calls (sessions only; the GT jumps have no sand mark).
final class SandMarkTests: XCTestCase {
    private func box(_ v: [Double]) -> SIMD4<Double> { SIMD4(v[0], v[1], v[2], v[3]) }

    /// The recorded full-frame mask cropped to its bounding box (nil mask for an empty one).
    private func cropped(_ full: BinaryMask) -> RunnerMask {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<full.height {
            for x in 0..<full.width where full.data[y * full.width + x] != 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        if maxX < 0 { return RunnerMask(left: 0, top: 0, mask: BinaryMask(width: 0, height: 0)) }
        let w = maxX - minX + 1, h = maxY - minY + 1
        var out = BinaryMask(width: w, height: h)
        for y in 0..<h { for x in 0..<w { out.data[y * w + x] = full.data[(y + minY) * full.width + x + minX] } }
        return RunnerMask(left: minX, top: minY, mask: out)
    }

    private func point(_ v: JSONValue) -> SIMD2<Int>? {
        guard let a = v.arrayValue, a.count == 2 else { return nil }
        return SIMD2(a[0].intValue!, a[1].intValue!)
    }

    private func rule(_ v: JSONValue?) -> SandMarkRule {
        var r = SandMarkRule()
        guard let v else { return r }
        r.contactRatio = v["contact_ratio"]!.fixtureDouble!
        r.minJointScore = v["min_joint_score"]!.fixtureDouble!
        r.maxWindowS = v["max_window_s"]!.fixtureDouble!
        r.bboxMarginRatio = v["bbox_margin_ratio"]!.fixtureDouble!
        r.minRunnerIou = v["min_runner_iou"]!.fixtureDouble!
        r.batchSize = v["batch_size"]!.intValue!
        return r
    }

    func testBoardSideContact() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("board_side_contact") {
                let full = try XCTUnwrap(call.args["mask"]?.mask)
                let sandY = try call.arg("sand_y").fixtureDouble!
                let tol = try call.arg("tolerance").fixtureDouble!
                let right = try XCTUnwrap(call.args["board_on_right"]?.boolValue)
                let expected = point(call.result)
                for runner in [RunnerMask(fullFrame: full), cropped(full)] {
                    let got = SandMarkFinder.boardSideContact(mask: runner, sandY: sandY, tolerance: tol, boardOnRight: right)
                    XCTAssertEqual(got, expected, "\(c.name) #\(n)")
                }
                n += 1
            }
        }
        print("board_side_contact replayed: \(n)")
    }

    func testSandSurfaceYAndNearestJoint() throws {
        var ny = 0, nj = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("sand_surface_y") {
                let track = try c.track(call.arg("track"))
                let y = try SandMarkFinder.sandSurfaceY(track: track, index: call.arg("index").intValue!)
                XCTAssertEqual(y, call.result.fixtureDouble!, c.name)
                ny += 1
            }
            for call in try c.calls("nearest_joint") {
                let track = try c.track(call.arg("track"))
                let p = try XCTUnwrap(point(call.arg("point")))
                let j = SandMarkFinder.nearestJoint(
                    track: track, index: try call.arg("index").intValue!, point: p,
                    minScore: try call.arg("min_score").fixtureDouble!)
                XCTAssertEqual(j, call.result.stringValue, c.name)
                nj += 1
            }
        }
        print("sand_surface_y replayed: \(ny), nearest_joint replayed: \(nj)")
    }

    func testBodyPart() {
        XCTAssertEqual(SandMarkFinder.bodyPart(ofJoint: "right_hip"), "buttocks")
        XCTAssertEqual(SandMarkFinder.bodyPart(ofJoint: "left_big_toe"), "foot")
        XCTAssertEqual(SandMarkFinder.bodyPart(ofJoint: "left_small_toe"), "foot")
        XCTAssertEqual(SandMarkFinder.bodyPart(ofJoint: "left_wrist"), "hand")
        XCTAssertEqual(SandMarkFinder.bodyPart(ofJoint: "nose"), nil)
        XCTAssertEqual(SandMarkFinder.bodyPart(ofJoint: nil), nil)
        XCTAssertEqual(SandMarkFinder.bodyPart(ofJoint: ""), nil)
    }

    func testNearestContactInBatch() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("_nearest_contact_in_batch") {
                let batch = try call.arg("batch").arrayValue!.map { (frame: $0["frame"]!.intValue!, box: box($0["box"]!.doubles)) }
                let recorded = try XCTUnwrap(call.masks)
                let r = rule(call.args["rule"])
                let best = call.args["best"].flatMap { v -> SandMarkFinder.Contact? in
                    guard let a = v.arrayValue, a.count == 2 else { return nil }
                    return .init(frame: a[0].intValue!, point: point(a[1])!)
                }
                let right = call.args["board_on_right"]!.boolValue!
                let sandY = try call.arg("sand_y").fixtureDouble!
                var expected: SandMarkFinder.Contact?
                if let a = call.result.arrayValue, a.count == 2 {
                    expected = .init(frame: a[0].intValue!, point: point(a[1])!)
                }
                for crop in [false, true] {
                    let masks: [RunnerMask?] = recorded.map { m in
                        m.mask.map { crop ? cropped($0) : RunnerMask(fullFrame: $0) }
                    }
                    let got = SandMarkFinder.nearestContact(
                        batch: batch, masks: masks, sandY: sandY, rule: r, boardOnRight: right, best: best)
                    XCTAssertEqual(got, expected, "\(c.name) #\(n) crop=\(crop)")
                }
                n += 1
            }
        }
        print("_nearest_contact_in_batch replayed: \(n)")
    }

    private struct RecordedMasks: RunnerMaskSource {
        var byFrame: [Int: RunnerMask]
        func runnerMask(frame: Int, box: SIMD4<Double>) throws -> RunnerMask? { byFrame[frame] }
    }

    func testFindSandMark() throws {
        var n = 0
        for c in try LongJumpCase.all() {
            for call in try c.calls("find_sand_mark") {
                var byFrame: [Int: RunnerMask] = [:]
                var byFrameFull: [Int: RunnerMask] = [:]
                for inner in try c.calls("_nearest_contact_in_batch") {
                    let batch = try inner.arg("batch").arrayValue!
                    for (item, m) in zip(batch, inner.masks!) {
                        if let full = m.mask {
                            byFrame[item["frame"]!.intValue!] = cropped(full)
                            byFrameFull[item["frame"]!.intValue!] = RunnerMask(fullFrame: full)
                        }
                    }
                }
                let track = try c.track(call.arg("track"))
                let expected = try XCTUnwrap(SandMark(fixture: call.result))
                for source in [byFrame, byFrameFull] {
                    let got = try SandMarkFinder.findSandMark(
                        track: track, sandLandingFrame: call.arg("sand_landing_frame").intValue!,
                        runSide: try XCTUnwrap(call.arg("run_side").side), rule: rule(call.args["rule"]),
                        masks: RecordedMasks(byFrame: source))
                    XCTAssertEqual(got, expected, c.name)
                }
                n += 1
            }
        }
        print("find_sand_mark replayed: \(n)")
    }

    func testRoi() {
        for (w, h, b, expected) in roiCases {
            let roi = RunnerSegmentation.roi(frameWidth: w, frameHeight: h, runnerBox: box(b))
            XCTAssertEqual(roi.map { [$0.left, $0.top, $0.right, $0.bottom] }, expected, "\(b)")
        }
    }

    func testBoxIoU() {
        for (a, b, expected) in iouCases {
            XCTAssertEqual(RunnerSegmentation.boxIoU(box(a), box(b)), expected, "\(a) \(b)")
        }
    }

    func testChooseRunner() {
        var nilCount = 0
        for (b, r, dets, index, ious) in chooseCases {
            let roi = PixelROI(left: r[0], top: r[1], right: r[2], bottom: r[3])
            let f32 = dets.map { SIMD4<Float>(Float($0[0]), Float($0[1]), Float($0[2]), Float($0[3])) }
            XCTAssertEqual(RunnerSegmentation.chooseRunner(detections: f32, runnerBox: box(b), roi: roi), index, "\(b)")
            let local = SIMD4<Double>(b[0] - Double(r[0]), b[1] - Double(r[1]), b[2] - Double(r[0]), b[3] - Double(r[1]))
            for (d, expected) in zip(f32, ious) {
                XCTAssertEqual(iou(NPBox(d), NPBox(local)), expected, "iou \(b)")
            }
            if index == nil { nilCount += 1 }
        }
        XCTAssertGreaterThan(nilCount, 0)
        XCTAssertLessThan(nilCount, chooseCases.count)
    }
}
