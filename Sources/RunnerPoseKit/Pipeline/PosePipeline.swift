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
        DebugLog.mark("Pipeline: begin url=\(url.lastPathComponent)")
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
        DebugLog.mark(
            "Pipeline: prescan done ranges=\(prescanResult.ranges.count) keptFrames=\(prescanResult.ranges.reduce(0) { $0 + $1.numFrames }) totalFrames=\(prescanResult.totalFrames)"
        )

        // ---- S1..S5 over the valid ranges ----
        let videoInfo = try await VideoFrameReader.info(for: url)
        DebugLog.mark(
            "Pipeline: video info fps=\(videoInfo.nominalFPS) size=\(Int(videoInfo.frameSize.width))x\(Int(videoInfo.frameSize.height)) totalFrames=\(videoInfo.totalFrames)"
        )
        var tracker = BBoxTracker()
        var poses: [RunnerPose] = []
        var rows: [PerFrameRow] = []
        var detectionFrames = 0
        var extrapolatedFrames = 0
        var skippedByGate = 0
        config.progressHandler?(.init(
            stage: .processing,
            currentFrame: 0,
            totalFrames: prescanResult.totalFrames,
            message: "Processing \(prescanResult.ranges.reduce(0) { $0 + $1.numFrames }) kept frames"
        ))

        try await VideoFrameReader.forEachFrame(url: url, in: prescanResult.ranges) { frame in
            try Task.checkCancellation()
            if poses.isEmpty || poses.count % 30 == 0 {
                config.progressHandler?(.init(
                    stage: .processing,
                    currentFrame: frame.frameIndex,
                    totalFrames: prescanResult.totalFrames,
                    message: "Processing frame \(frame.frameIndex)"
                ))
            }

            var detectMs = 0.0, warpMs = 0.0, hrnetMs = 0.0, postMs = 0.0
            let frameSize = frame.frameSize

            // S2 — detect (cadence) or extrapolate, then gate.
            let isDetectFrame = frame.frameIndex % config.detectorCadence == 0
                || tracker.coastedFrames >= config.trackerStalenessLimit
            var box: BBox?
            var extrapolated = false

            if isDetectFrame {
                DebugLog.mark("Pipeline: frame \(frame.frameIndex) detect begin")
                let dT0 = DispatchTime.now().uptimeNanoseconds
                let dets = try await detector.detect(frame.pixelBuffer, frameSize: frameSize)
                detectMs = Double(DispatchTime.now().uptimeNanoseconds - dT0) / 1_000_000
                DebugLog.mark("Pipeline: frame \(frame.frameIndex) detect end dets=\(dets.count) ms=\(Int(detectMs))")
                if let runner = detector.pickRunner(dets, near: tracker.lastBox, frameSize: frameSize, config: config) {
                    tracker.observe(box: runner.box, frame: frame.frameIndex)
                    box = runner.box
                    detectionFrames += 1
                } else {
                    tracker.reset()
                }
            } else if let predicted = tracker.predict(frame: frame.frameIndex) {
                box = predicted
                extrapolated = true
                extrapolatedFrames += 1
            }

            guard let box else {
                skippedByGate += 1
                DebugLog.mark("Pipeline: frame \(frame.frameIndex) skipped by gate")
                let pose = RunnerPose(frameIndex: frame.frameIndex, timestamp: frame.timestamp,
                                      bbox: nil, joints: [], valid: false, bboxExtrapolated: extrapolated)
                poses.append(pose); onPose(pose)
                rows.append(row(frame, valid: false, extrapolated: extrapolated,
                                detectMs: detectMs, warpMs: 0, hrnetMs: 0, postMs: 0, thermal: thermal))
                return
            }

            // S3 — crop & warp
            DebugLog.mark("Pipeline: frame \(frame.frameIndex) warp begin")
            let w0 = DispatchTime.now().uptimeNanoseconds
            let warp = try cropWarp.makeCrop(from: frame.pixelBuffer, box: box,
                                             frameSize: frameSize)
            warpMs = ms(since: w0)
            DebugLog.mark("Pipeline: frame \(frame.frameIndex) warp end ms=\(Int(warpMs))")

            // S4 — HRNet
            DebugLog.mark("Pipeline: frame \(frame.frameIndex) hrnet begin")
            let h0 = DispatchTime.now().uptimeNanoseconds
            let heat = try hrnet.predict(crop: warp.crop)
            hrnetMs = ms(since: h0)
            DebugLog.mark("Pipeline: frame \(frame.frameIndex) hrnet end ms=\(Int(hrnetMs))")

            // S5 — DarkPose decode + inverse affine
            DebugLog.mark("Pipeline: frame \(frame.frameIndex) postproc begin")
            let p0 = DispatchTime.now().uptimeNanoseconds
            let joints = decoder.decode(heatmap: heat, center: warp.info.center, scale: warp.info.scale)
            postMs = ms(since: p0)
            DebugLog.mark("Pipeline: frame \(frame.frameIndex) postproc end ms=\(Int(postMs))")

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
        DebugLog.mark("Pipeline: end poses=\(poses.count) valid=\(processed) wall=\(String(format: "%.2f", wall))s")
        config.progressHandler?(.init(
            stage: .finished,
            currentFrame: prescanResult.totalFrames,
            totalFrames: prescanResult.totalFrames,
            message: "Finished: \(processed) valid poses"
        ))
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
