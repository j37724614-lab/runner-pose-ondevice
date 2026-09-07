import AVFoundation
import CoreMedia
import Foundation

/// Drives S0…S5 for one video and produces the `RunnerPose` stream + a `BenchReport`.
///
/// **This is the P1 naive baseline: strictly sequential, one frame at a time.**
/// The bounded-parallel version (five stages, depth-limited channel, back-pressure)
/// is the headline P2 optimisation — see 規劃書 §04 管線並行. Keep this version around
/// as the correctness reference and the "naive" row in the §08 matrix.
struct PosePipeline {
    let config: Config
    let detector: PersonDetector
    let hrnet: HRNetRunner
    let cropWarp: CropWarp
    let decoder: HeatmapDecoder

    struct Output {
        var poses: [RunnerPose]
        var report: BenchReport
        var perFrame: [PerFrameRow]
    }

    func run(
        url: URL,
        conditions base: BenchReport.Conditions,
        onPose: (RunnerPose) -> Void
    ) async throws -> Output {
        let wall0 = Date()
        var timer = StageTimer()
        let mem = MemorySampler(); mem.start()
        let thermal = ThermalSampler(); thermal.start()
        defer { mem.stop(); thermal.stop() }

        // ---- S0 prescan ----
        let prescan = PrescanFilter(config: config, detector: detector)
        let prescanT0 = DispatchTime.now().uptimeNanoseconds
        let prescanResult = try await prescan.scan(url: url)
        timer.record(.prescan, ms: Double(DispatchTime.now().uptimeNanoseconds - prescanT0) / 1_000_000)

        // ---- S1..S5 over the valid ranges ----
        let videoInfo = try await VideoFrameReader.info(for: url)
        var tracker = BBoxTracker()
        var poses: [RunnerPose] = []
        var rows: [PerFrameRow] = []
        var detectionFrames = 0
        var extrapolatedFrames = 0
        var skippedByGate = 0

        for try await frame in VideoFrameReader.frames(url: url, in: prescanResult.ranges) {
            try Task.checkCancellation()

            var detectMs = 0.0, warpMs = 0.0, hrnetMs = 0.0, postMs = 0.0

            // S2 — detect (cadence) or extrapolate, then gate.
            let isDetectFrame = frame.frameIndex % config.detectorCadence == 0
                || tracker.coastedFrames >= config.trackerStalenessLimit
            var box: BBox?
            var extrapolated = false

            if isDetectFrame {
                let dT0 = DispatchTime.now().uptimeNanoseconds
                let dets = try await detector.detect(frame.pixelBuffer, frameSize: videoInfo.frameSize)
                detectMs = Double(DispatchTime.now().uptimeNanoseconds - dT0) / 1_000_000
                if let runner = detector.pickRunner(dets, near: tracker.lastBox, config: config) {
                    tracker.observe(box: runner.box, frame: frame.frameIndex)
                    box = runner.box
                    detectionFrames += 1
                }
            } else if let predicted = tracker.predict(frame: frame.frameIndex) {
                box = predicted
                extrapolated = true
                extrapolatedFrames += 1
            }

            guard let box else {
                skippedByGate += 1
                let pose = RunnerPose(frameIndex: frame.frameIndex, timestamp: frame.timestamp,
                                      bbox: nil, joints: [], valid: false, bboxExtrapolated: extrapolated)
                poses.append(pose); onPose(pose)
                rows.append(row(frame, valid: false, extrapolated: extrapolated,
                                detectMs: detectMs, warpMs: 0, hrnetMs: 0, postMs: 0, thermal: thermal))
                continue
            }

            // S3 — crop & warp
            let w0 = DispatchTime.now().uptimeNanoseconds
            let warp = try cropWarp.makeCrop(from: frame.pixelBuffer, box: box,
                                             frameSize: videoInfo.frameSize)
            warpMs = ms(since: w0)

            // S4 — HRNet
            let h0 = DispatchTime.now().uptimeNanoseconds
            let heat = try hrnet.predict(crop: warp.crop)
            hrnetMs = ms(since: h0)

            // S5 — DarkPose decode + inverse affine
            let p0 = DispatchTime.now().uptimeNanoseconds
            let joints = decoder.decode(heatmap: heat, center: warp.info.center, scale: warp.info.scale)
            postMs = ms(since: p0)

            timer.record(.detect, ms: detectMs)
            timer.record(.warp, ms: warpMs)
            timer.record(.hrnet, ms: hrnetMs)
            timer.record(.postproc, ms: postMs)

            let pose = RunnerPose(frameIndex: frame.frameIndex, timestamp: frame.timestamp,
                                  bbox: box, joints: joints, valid: true, bboxExtrapolated: extrapolated)
            poses.append(pose); onPose(pose)
            rows.append(row(frame, valid: true, extrapolated: extrapolated,
                            detectMs: detectMs, warpMs: warpMs, hrnetMs: hrnetMs, postMs: postMs,
                            thermal: thermal))
        }

        // ---- assemble report ----
        let wall = Date().timeIntervalSince(wall0)
        let processed = poses.filter(\.valid).count
        var conditions = base
        conditions.videoFrames = prescanResult.totalFrames
        conditions.videoFPS = videoInfo.nominalFPS
        conditions.startThermalState = thermal.transitions.first?.state ?? "unknown"

        var stages: [String: StageStats] = [:]
        for s in StageTimer.Stage.allCases {
            if let st = timer.summary(for: s, warmup: 0) { stages[s.rawValue] = st }
        }

        let report = BenchReport(
            id: UUID(),
            startedAt: wall0,
            conditions: conditions,
            totals: .init(
                wallClockSeconds: wall,
                framesProcessed: processed,
                framesSkippedByGate: skippedByGate,
                validRangeFrames: prescanResult.ranges.reduce(0) { $0 + $1.numFrames },
                totalVideoFrames: prescanResult.totalFrames,
                effectiveFPS: wall > 0 ? Double(poses.count) / wall : 0,
                modelLoadSeconds: hrnet.loadSeconds,
                prescanSeconds: prescanResult.elapsed,
                prescanKeptRatio: prescanResult.keptRatio,
                detectionFrames: detectionFrames,
                extrapolatedFrames: extrapolatedFrames
            ),
            stages: stages,
            memory: .init(peakMB: mem.peakMB, samplesMB: mem.samplesMB, receivedMemoryWarning: false),
            thermal: thermal.transitions,
            perFrameCSVName: nil
        )
        return Output(poses: poses, report: report, perFrame: rows)
    }

    // MARK: - small timing helpers

    private func row(_ f: DecodedFrame, valid: Bool, extrapolated: Bool,
                     detectMs: Double, warpMs: Double, hrnetMs: Double, postMs: Double,
                     thermal: ThermalSampler) -> PerFrameRow {
        PerFrameRow(
            frameIndex: f.frameIndex,
            timeSeconds: f.timestamp.seconds,
            valid: valid,
            bboxExtrapolated: extrapolated,
            decodeMs: 0, // S1 timing is folded into the stream; TODO(mac): expose per-frame decode
            detectMs: detectMs,
            warpMs: warpMs,
            hrnetMs: hrnetMs,
            postprocMs: postMs,
            thermalState: ThermalSampler.name(ProcessInfo.processInfo.thermalState),
            footprintMB: MemorySampler.footprintMB() ?? 0
        )
    }
}

/// Milliseconds elapsed since a `DispatchTime.now().uptimeNanoseconds` mark.
private func ms(since t0: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
}
