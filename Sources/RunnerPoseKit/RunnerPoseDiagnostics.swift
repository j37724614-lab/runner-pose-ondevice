import CoreVideo
import Foundation

public enum RunnerPoseDiagnostics {
    public static func runDummyInput(
        config: Config = Config(),
        includeDetector: Bool = true,
        includeHRNet: Bool = true
    ) async -> [String] {
        var lines: [String] = []

        func record(_ message: String) {
            lines.append(message)
            DebugLog.mark("Dummy: \(message)")
        }

        record("begin detector=\(config.detectorModel.rawValue) computeUnits=\(config.computeUnits)")

        if includeDetector {
            do {
            let detector = try DetectorFactory.make(config)

            let detectorWarmupStart = Date()
            try await withTimeout(seconds: 20, label: "detector warmUp") {
                await detector.warmUp()
            }
            record("detector warmUp ok ms=\(milliseconds(since: detectorWarmupStart))")

            let detectStart = Date()
            let detections = try await withTimeout(seconds: 20, label: "detector dummy detect") {
                let detectorFrame = try blankPixelBuffer(width: config.detectorImageSize, height: config.detectorImageSize)
                return try await detector.detect(
                    detectorFrame,
                    frameSize: CGSize(width: config.detectorImageSize, height: config.detectorImageSize)
                )
            }
            record("detector dummy detect ok detections=\(detections.count) ms=\(milliseconds(since: detectStart))")
        } catch {
            record("detector failed: \(error)")
            }
        } else {
            record("detector skipped")
        }

        if includeHRNet {
            do {
            let hrnetStart = Date()
            let hrnet = try await withTimeout(seconds: 20, label: "HRNet load") {
                try HRNetRunner(config: config)
            }
            record("HRNet load ok ms=\(milliseconds(since: hrnetStart))")

            let predictStart = Date()
            let heatmap = try await withTimeout(seconds: 20, label: "HRNet dummy predict") {
                let crop = try blankPixelBuffer(width: config.hrnetInputWidth, height: config.hrnetInputHeight)
                return try hrnet.predict(crop: crop)
            }
            record("HRNet dummy predict ok shape=\(heatmap.shape.map(\.intValue)) ms=\(milliseconds(since: predictStart))")
        } catch {
            record("HRNet failed: \(error)")
            }
        } else {
            record("HRNet skipped")
        }

        record("end")
        return lines
    }

    private static func blankPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw RunnerPoseError.cropWarpSetup(status)
        }
        return pixelBuffer
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private static func withTimeout<T: Sendable>(
        seconds: UInt64,
        label: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let state = TimeoutState<T>()
        let operationTask = Task.detached {
            do {
                await state.finish(.success(try await operation()))
            } catch {
                await state.finish(.failure(error))
            }
        }
        let timeoutTask = Task.detached {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            await state.finish(.failure(DiagnosticTimeoutError(label: label, seconds: seconds)))
        }

        let result = await state.value()
        operationTask.cancel()
        timeoutTask.cancel()
        return try result.get()
    }
}

private actor TimeoutState<T: Sendable> {
    private var result: Result<T, Error>?
    private var waiters: [CheckedContinuation<Result<T, Error>, Never>] = []

    func finish(_ result: Result<T, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    func value() async -> Result<T, Error> {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private struct DiagnosticTimeoutError: Error, CustomStringConvertible {
    var label: String
    var seconds: UInt64

    var description: String {
        "\(label) timed out after \(seconds)s"
    }
}
