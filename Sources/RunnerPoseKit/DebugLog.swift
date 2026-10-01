import Foundation

enum DebugLog {
    static func mark(_ message: @autoclosure () -> String) {
        #if DEBUG
        let timestamp = String(format: "%.3f", Date().timeIntervalSinceReferenceDate)
        print("[RunnerPoseDebug] \(timestamp) \(message())")
        #endif
    }
}
