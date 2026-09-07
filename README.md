# runner-pose-ondevice

On-device 2D runner-pose extraction for iOS. Takes a local video, runs the trained
**HRNet-W48 wholebody-23** Core ML model on the phone (ANE / GPU / CPU), and emits
per-frame 23-point skeletons — the video never leaves the device.

This is the **first production component** of the on-device migration: it replaces the
"upload video → server HRNet" leg of the current pipeline. The rest (3D lifting, gait,
overlay) stays on the server for now and receives only keypoints.

Full design: **[docs/PLAN.md](docs/PLAN.md)** (規劃書 v0.2). Section numbers below (§NN)
refer to it.

---

## Status

Scaffold. Written on Linux; **not yet compiled**. Swift is a complete skeleton with the
numeric algorithms ported from the Python pipeline and marked `// TODO(mac):` where a
device API or a value needs verification in Xcode. `scripts/` is runnable on Linux now.

| Part | State |
|---|---|
| `scripts/` (Python tooling) | runnable on Linux; test target for prescan / accuracy parity |
| `Sources/RunnerPoseKit/` | full skeleton, algorithm ports done, unbuilt |
| `Tests/RunnerPoseKitTests/` | parity-test structure, needs fixtures + a Mac |
| `BenchApp/` | SwiftUI sources, needs an Xcode project (`xcodegen` or manual) |
| `flutter/runner_pose/` | plugin skeleton (P5) |

---

## Machines

| Machine | Path | What runs here |
|---|---|---|
| **Mac** (Xcode 15, iOS 16 SDK) | e.g. `~/Developer/runner-pose-ondevice` | everything: `RunnerPoseKit`, `BenchApp`, tests, on-device benchmarks |
| **Linux** `catslab` | `/home/jeter/runner-pose-ondevice` | `scripts/` + `testdata/` only; `RunnerPoseKit/` does not build here |

Same git remote both sides.

---

## First run on the Mac

```bash
# 1. models (see Sources/RunnerPoseKit/Resources/README.md)
#    - HRNetRunnerWholeBody23.mlpackage        (from runner-analysis-pipeline)
#    - yolo26n/s/m/l.mlpackage                 (from ultralytics/yolo-ios-app v8.3.0 release)

# 2. build the package
swift build

# 3. run the parity tests (needs Fixtures/, see Tests/README.md)
swift test

# 4. BenchApp: generate the Xcode project, then run on a device
#    (Release build — Debug hides real ANE latency; 規劃書 §07)
```

## First run on Linux (tooling)

```bash
cd /home/jeter/runner-pose-ondevice
python -m venv .venv && . .venv/bin/activate
pip install -r scripts/requirements.txt

# produce the S0 parity baseline for each candidate detector scale
python scripts/make_prescan_reference.py \
  --videos testdata/videos --scales n s m l --out testdata/prescan_reference

# desktop ground-truth keypoints for the accuracy comparison (§07)
python scripts/make_ground_truth.py --help
python scripts/compare_accuracy.py --help
```

---

## Pipeline (規劃書 §03)

```
video ─▶ S0 PrescanFilter ─▶ [CMTimeRange]
                              │  (only these frames continue)
        S1 VideoFrameReader ─▶ S2 PersonDetector+Tracker+Gate ─▶ S3 CropWarp
                                                                    │
        S5 HeatmapDecoder ◀─ S4 HRNetRunner ◀───────────────────────┘
                              │
                              ▼
                        AsyncThrowingStream<RunnerPose>
```

S0 and S2 share one detector instance (`Config.detectorModel`, default `.yolo26n`).
