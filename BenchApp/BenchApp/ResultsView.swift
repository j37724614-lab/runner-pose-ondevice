import SwiftUI
import RunnerPoseKit

/// The accumulated run history — the §08 先導 detector selection table lives here.
struct ResultsView: View {
    let history: [BenchReport]
    let onClear: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(grouped, id: \.key) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.key).font(.subheadline.bold())
                            Text(String(format: "n=%d   eff.fps μ%.1f   hrnet μ%.1f ms   detect μ%.1f ms   peak %.0f MB",
                                        group.count, group.effFPS, group.hrnetMs, group.detectMs, group.peakMB))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("grouped by detector / cadence / compute / variant")
                }

                Section("raw runs (\(history.count))") {
                    ForEach(history.reversed(), id: \.id) { r in
                        VStack(alignment: .leading) {
                            Text("\(r.conditions.detectorModel) · cad \(r.conditions.detectorCadence) · \(r.conditions.computeUnits) · \(r.conditions.implementationVariant)")
                                .font(.caption.bold())
                            Text(String(format: "%@ · %.1f fps · hrnet p90 %.1f ms · %.0f MB",
                                        r.conditions.videoName, r.totals.effectiveFPS,
                                        r.stages["hrnet"]?.p90 ?? 0, r.memory.peakMB))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Results")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) { onClear() }
                }
            }
        }
    }

    private struct Group {
        var key: String
        var count: Int
        var effFPS: Double
        var hrnetMs: Double
        var detectMs: Double
        var peakMB: Double
    }

    private var grouped: [Group] {
        Dictionary(grouping: history) { r in
            "\(r.conditions.detectorModel) / cad\(r.conditions.detectorCadence) / \(r.conditions.computeUnits) / \(r.conditions.implementationVariant)"
        }
        .map { key, runs in
            func med(_ f: (BenchReport) -> Double) -> Double {
                let v = runs.map(f).sorted()
                return v.isEmpty ? 0 : v[v.count / 2]
            }
            return Group(
                key: key, count: runs.count,
                effFPS: med { $0.totals.effectiveFPS },
                hrnetMs: med { $0.stages["hrnet"]?.mean ?? 0 },
                detectMs: med { $0.stages["detect"]?.mean ?? 0 },
                peakMB: med { $0.memory.peakMB }
            )
        }
        .sorted { $0.key < $1.key }
    }
}
