import XCTest
@testable import RunnerPoseKit

/// Long-video footprint must not grow with frame count — the leak guard for the
/// bounded-parallel pipeline and the buffer pools (規劃書 §04 / §09 正式化門檻).
///
/// Needs a device build + a bundled test video + the .mlpackage resources, so it
/// skips on plain `swift test`. Wire it up in the Xcode test plan for the Mac /
/// device run.
final class PipelineMemoryTests: XCTestCase {

    /// Drop a short clip here (git-ignored) to enable.
    private var testVideoURL: URL? {
        Bundle.module.url(forResource: "mem_probe", withExtension: "mp4", subdirectory: "Fixtures")
    }

    func testFootprintIsFlatOverLongVideo() async throws {
        guard let url = testVideoURL else {
            throw XCTSkip("no Fixtures/mem_probe.mp4 — see PLAN §04 / this file's header")
        }
        let engine = try await RunnerPoseEngine(config: Config())
        await engine.warmUp()

        var footprints: [Double] = []
        let cond = await RunnerPoseEngine.baseConditions(
            videoName: url.lastPathComponent,
            implementationVariant: "test"
        )
        for try await pose in engine.poses(for: url, conditions: cond) {
            if pose.frameIndex % 30 == 0, let mb = MemorySampler.footprintMB() {
                footprints.append(mb)
            }
        }
        guard footprints.count > 4 else { throw XCTSkip("too few frames") }

        // linear-fit slope over samples; expect near-flat.
        let n = Double(footprints.count)
        let xs = (0..<footprints.count).map(Double.init)
        let mx = xs.reduce(0, +) / n
        let my = footprints.reduce(0, +) / n
        let slope = zip(xs, footprints).reduce(0.0) { $0 + ($1.0 - mx) * ($1.1 - my) }
            / xs.reduce(0.0) { $0 + pow($1 - mx, 2) }

        XCTAssertLessThan(abs(slope), 0.5, "footprint grows \(slope) MB per 30-frame sample")
    }
}
