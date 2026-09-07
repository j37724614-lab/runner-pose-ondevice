import Foundation

/// Append-only, on-device history of every BenchApp run (規劃書 §03 累積記錄 / §08 先導).
///
/// The §08 detector-scale sweep is just: pick a scale in the BenchApp picker, run,
/// repeat — then read this table. No desktop driver.
///
/// `@unchecked Sendable`: all mutable state goes through the serial `queue`.
public final class BenchResultStore: @unchecked Sendable {
    public static let shared = BenchResultStore()

    private let dir: URL
    private let indexURL: URL
    private let queue = DispatchQueue(label: "runnerpose.resultstore")

    public private(set) var reports: [BenchReport] = []

    public init(directory: URL? = nil) {
        let base = directory ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("RunnerPoseBench", isDirectory: true)
        indexURL = dir.appendingPathComponent("runs.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reports = (try? load()) ?? []
    }

    public func append(_ report: BenchReport, perFrame rows: [PerFrameRow]) {
        queue.sync {
            reports.append(report)
            if !rows.isEmpty {
                let csv = ([PerFrameRow.csvHeader] + rows.map(\.csvLine)).joined(separator: "\n")
                let name = "\(report.id.uuidString).csv"
                try? csv.data(using: .utf8)?.write(to: dir.appendingPathComponent(name))
            }
            try? persist()
        }
    }

    public func clear() {
        queue.sync {
            reports.removeAll()
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Everything zipped for `xcrun devicectl` pull / share sheet.
    public func exportBundleURL() throws -> URL { dir }

    private func persist() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(reports).write(to: indexURL)
    }

    private func load() throws -> [BenchReport] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode([BenchReport].self, from: Data(contentsOf: indexURL))
    }
}
