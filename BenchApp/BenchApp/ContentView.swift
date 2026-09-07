import SwiftUI
import RunnerPoseKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var runner = BenchRunner()
    @State private var videoURL: URL?
    @State private var showImporter = false
    @State private var runIndex = 0
    @State private var showResults = false

    var body: some View {
        NavigationStack {
            Form {
                videoSection
                knobsSection
                runSection
                if let r = runner.lastReport { ResultCard(report: r) }
                if let e = runner.errorText {
                    Section { Text(e).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("HRNet Bench")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Results (\(runner.history.count))") { showResults = true }
                }
            }
            .sheet(isPresented: $showResults) {
                ResultsView(history: runner.history, onClear: runner.clearHistory)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) {
                if case .success(let url) = $0 {
                    _ = url.startAccessingSecurityScopedResource()
                    videoURL = url
                }
            }
        }
    }

    private var videoSection: some View {
        Section("Video") {
            Button {
                showImporter = true
            } label: {
                Label(videoURL?.lastPathComponent ?? "Choose a local video…", systemImage: "film")
            }
            Text("Stays on device. Nothing is uploaded.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var knobsSection: some View {
        Section("Knobs") {
            Picker("Detector", selection: $runner.detector) {
                ForEach([DetectorModel.yolo26n, .yolo26s, .yolo26m, .yolo26l, .visionHuman], id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            Picker("Compute", selection: $runner.computeUnit) {
                ForEach(BenchRunner.ComputeUnitChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            Stepper("Detector cadence: \(runner.detectorCadence)", value: $runner.detectorCadence, in: 1...12)
            Stepper("Max in flight: \(runner.maxInFlight)", value: $runner.maxInFlight, in: 1...6)
            Stepper("Warmup runs: \(runner.warmupRuns)", value: $runner.warmupRuns, in: 0...5)
            Picker("Variant", selection: $runner.implementationVariant) {
                Text("naive").tag("naive")
                Text("optimized").tag("optimized")
            }
        }
    }

    private var runSection: some View {
        Section {
            Button {
                guard let url = videoURL else { return }
                runIndex += 1
                runner.run(video: url, runIndex: runIndex)
            } label: {
                HStack {
                    Image(systemName: runner.isRunning ? "hourglass" : "play.fill")
                    Text(runner.isRunning ? "Running…" : "Run")
                }
            }
            .disabled(videoURL == nil || runner.isRunning)

            if runner.isRunning {
                ProgressView(value: runner.progress)
                HStack {
                    Text("frame \(runner.currentFrame)")
                    Spacer()
                    Text(String(format: "%.1f fps", runner.liveFPS)).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
                Button("Cancel", role: .destructive) { runner.cancel() }
            }
        }
    }
}

struct ResultCard: View {
    let report: BenchReport

    var body: some View {
        Section("Last run") {
            row("wall clock", String(format: "%.2f s", report.totals.wallClockSeconds))
            row("effective FPS", String(format: "%.1f", report.totals.effectiveFPS))
            row("frames processed", "\(report.totals.framesProcessed) / gate-skipped \(report.totals.framesSkippedByGate)")
            row("prescan", String(format: "%.2f s · kept %.0f%%",
                                  report.totals.prescanSeconds, report.totals.prescanKeptRatio * 100))
            row("detect frames", "\(report.totals.detectionFrames) fresh / \(report.totals.extrapolatedFrames) extrapolated")
            row("model load", String(format: "%.2f s", report.totals.modelLoadSeconds))
            row("peak memory", String(format: "%.0f MB", report.memory.peakMB))
            row("thermal", report.thermal.map(\.state).joined(separator: " → "))

            ForEach(["prescan", "decode", "detect", "warp", "hrnet", "postproc"], id: \.self) { key in
                if let s = report.stages[key] {
                    row("\(key) ms", String(format: "μ%.1f  p50 %.1f  p90 %.1f  max %.1f",
                                            s.mean, s.p50, s.p90, s.max))
                }
            }

            ShareLink(item: ExportedReport(report: report), preview: SharePreview("BenchReport"))
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            .font(.callout)
    }
}

/// Wrap a BenchReport as a shareable JSON file.
struct ExportedReport: Transferable {
    let report: BenchReport
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { item in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(item.report.id.uuidString).json")
            try item.report.jsonData().write(to: url)
            return SentTransferredFile(url)
        }
    }
}
