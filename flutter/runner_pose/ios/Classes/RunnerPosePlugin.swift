import Flutter
import UIKit
import RunnerPoseKit

/// P5 bridge skeleton (規劃書 §05 P5 / §11).
///
/// Real implementation: generate the typed channel with Pigeon
/// (`pigeons/messages.dart`), then in `analyze(...)` build a `Config` from the
/// Dart-supplied `RunnerPoseConfig`, create/reuse a `RunnerPoseEngine`, and forward
/// `engine.poses(for:)` onto a Flutter `EventChannel` — one event per `RunnerPose`,
/// a final event carrying the `BenchReport`.
public class RunnerPosePlugin: NSObject, FlutterPlugin {

    private var engine: RunnerPoseEngine?
    private var streamTask: Task<Void, Never>?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = RunnerPosePlugin()
        let method = FlutterMethodChannel(name: "runner_pose/method", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: method)

        let events = FlutterEventChannel(name: "runner_pose/poses", binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "warmUp":
            Task { [weak self] in
                if self?.engine == nil { self?.engine = try? await RunnerPoseEngine() }
                await self?.engine?.warmUp()
                result(nil)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

extension RunnerPosePlugin: FlutterStreamHandler {
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        guard let args = arguments as? [String: Any],
              let path = args["videoPath"] as? String else {
            return FlutterError(code: "bad_args", message: "videoPath required", details: nil)
        }
        // TODO(P5): map args -> Config; reuse engine across runs.
        streamTask = Task { [weak self] in
            do {
                let engine: RunnerPoseEngine
                if let existing = self?.engine {
                    engine = existing
                } else {
                    engine = try await RunnerPoseEngine()
                    self?.engine = engine
                }
                let url = URL(fileURLWithPath: path)
                let cond = RunnerPoseEngine.baseConditions(videoName: url.lastPathComponent, implementationVariant: "release")
                let stream = await engine.poses(for: url, conditions: cond)
                for try await pose in stream {
                    let payload: [String: Any] = [
                        "frame": pose.frameIndex,
                        "time_s": pose.timestamp.seconds,
                        "valid": pose.valid,
                        "joints": pose.joints.map { [$0.x, $0.y, $0.score] },
                    ]
                    await MainActor.run { events(payload) }
                }
                await MainActor.run { events(FlutterEndOfEventStream) }
            } catch {
                await MainActor.run { events(FlutterError(code: "run_failed", message: "\(error)", details: nil)) }
            }
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        streamTask?.cancel()
        return nil
    }
}
