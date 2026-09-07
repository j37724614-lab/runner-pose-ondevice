# BenchApp

Thin SwiftUI shell over `RunnerPoseKit` — **no inference logic of its own**, so what it
measures is exactly the production module (規劃書 §03).

What it does:
- pick a local video (PhotosPicker / fileImporter)
- pick **detector model** `yolo26n / s / m / l`, compute unit, `detectorCadence`,
  `maxInFlight`, warmup count
- Run → progress + live FPS
- result card: totals, per-stage mean/p50/p90/max (S0 prescan and S2 detect shown
  separately), model-load time, peak memory, thermal trace
- every run is appended to an on-device history (`BenchResultStore`) — the §08 先導
  detector sweep is just "pick a scale, run, repeat, read the table"
- export: share `BenchReport` JSON + per-frame CSV (or pull the whole store with
  `xcrun devicectl device copy`)

## Generating the Xcode project

No `.xcodeproj` is committed. Use [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
cd BenchApp
xcodegen generate          # reads project.yml
open BenchApp.xcodeproj
```

Then add the model files (see `../Sources/RunnerPoseKit/Resources/README.md`) — the
package depends on them being present.

**Build Release for real numbers.** Debug hides ANE latency (規劃書 §07).
