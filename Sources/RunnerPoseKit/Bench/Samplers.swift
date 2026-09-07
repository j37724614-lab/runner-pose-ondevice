import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Polls resident memory every 250 ms while a run is in flight (規劃書 §06 記憶體).
public final class MemorySampler: @unchecked Sendable {
    private var timer: DispatchSourceTimer?
    private var _samples: [Double] = []
    private let queue = DispatchQueue(label: "runnerpose.memsampler")

    public init() {}

    public var samplesMB: [Double] { queue.sync { _samples } }
    public var peakMB: Double { queue.sync { _samples.max() ?? 0 } }

    public func start(interval: TimeInterval = 0.25) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self, let mb = Self.footprintMB() else { return }
            self._samples.append(mb) // already on `queue`
        }
        t.resume()
        queue.sync { timer = t }
    }

    public func stop() { queue.sync { timer?.cancel(); timer = nil } }

    /// `task_vm_info.phys_footprint` in MB (規劃書 §04 / §06).
    static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }
}

/// Records thermal-state transitions with timestamps (規劃書 §06 熱).
public final class ThermalSampler: @unchecked Sendable {
    public struct Transition: Codable, Sendable {
        public var atSeconds: Double
        public var state: String
    }

    private let lock = NSLock()
    private var _transitions: [Transition] = []
    private var startDate = Date()
    private var observer: NSObjectProtocol?

    public init() {}

    public var transitions: [Transition] { lock.withLock { _transitions } }

    public func start() {
        lock.withLock {
            startDate = Date()
            _transitions = [Transition(atSeconds: 0, state: Self.name(ProcessInfo.processInfo.thermalState))]
        }
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock {
                self._transitions.append(Transition(
                    atSeconds: Date().timeIntervalSince(self.startDate),
                    state: Self.name(ProcessInfo.processInfo.thermalState)
                ))
            }
        }
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    static func name(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
