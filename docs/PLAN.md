# 規劃書 (v0.2)

The full plan is **[plan.html](plan.html)** — open it in a browser (or the published
artifact). This file is a map from the plan's sections to the code.

| §  | Plan section | Where in this repo |
|----|--------------|--------------------|
| 01 | 概述與範圍 | `README.md` |
| 02 | 前提與限制（模型契約、prescan、compute units） | `Sources/RunnerPoseKit/Config.swift`, `Geometry.swift`, `HRNetRunner.swift` |
| 03 | 模組架構（API + S0–S5） | `RunnerPoseEngine.swift`, `Pipeline/*`, `BenchApp/` |
| 04 | 效能最佳化策略 | `HRNetRunner.swift` (outputBackings, mlmodelc cache), `CropWarp.swift` (pool, IOSurface), `PosePipeline.swift` (P2: bounded parallel), `HeatmapDecoder.swift` (P2: vDSP), `PrescanFilter.swift` (S0 skips empty stretches) |
| 05 | 執行階段 P0–P5 | see below |
| 06 | 量測指標目錄 | `Bench/StageTimer.swift`, `Samplers.swift`, `BenchReport.swift` |
| 07 | 精度比對方法 | `scripts/make_ground_truth.py`, `compare_accuracy.py`, `dump_parity_fixtures.py`; `Tests/*ParityTests.swift` |
| 08 | 測試矩陣（含偵測器先導） | `BenchApp/ResultsView.swift`, `scripts/bench_delta.py` |
| 09 | 判定標準與正式化門檻 | `Tests/` + `report/performance.md` |
| 10 | Repo 結構 | this tree |
| 11 | 整合進主流程 | `flutter/runner_pose/`, `report/integration_guide.md` |
| 12 | 風險與待確認 | tracked as `TODO(confirm)` / `TODO(mac)` in code |

## Phase status

- **P0** — repo scaffold done (this tree). `scripts/prescan_merge.py` parity table
  PASSES on Linux. Still needs: device inventory, backend prescan params
  (`minBoxHeight` etc. — `TODO(confirm)` in `Config.swift`), test videos in
  `testdata/videos/`, then run `scripts/make_prescan_reference.py`.
- **P1** — Swift skeleton + numeric ports written, **not yet compiled on a Mac**
  (~30 Swift files). Done: `Geometry` (box_to_center_scale + affine solve),
  `HeatmapDecoder` (get_max_preds + DarkPose blur/Taylor + inverse affine, naive
  baseline), `PrescanFilter.mergeHitFrames`, `RunnerPoseEngine` actor API,
  `PosePipeline` naive sequential, `BenchApp` UI, all Bench harness types.
  **Outstanding for P1:**
  1. `swift build` on the Mac, fix concurrency warnings.
  2. Wire the real `UltralyticsYOLO` calls in `PersonDetector.YOLO26Detector`
     (`detect` + `warmUp` are `TODO(mac)`).
  3. Generate fixtures (`scripts/dump_parity_fixtures.py`) → `GeometryParityTests`
     + `DarkPoseParityTests` green (< 0.5 px). ← **acceptance gate**
  4. `OutputSchemaTests` against a frozen pipeline keypoints file.
  5. Verify vImage warp direction / DarkPose Gaussian border vs cv2 (`TODO(mac)` in
     `CropWarp.swift` / `HeatmapDecoder.swift`).
- **P2** — not started. `PosePipeline` is the naive sequential baseline; the
  bounded-parallel rewrite + vDSP DarkPose + optional Metal are the optimisation
  passes (see `report/optimization_log.md`).
- **P3 / P4** — device work; use `BenchApp` + `scripts/bench_delta.py`.
- **P5** — `flutter/runner_pose/` skeleton only; Pigeon messages + backend
  `/analyze/keypoints` endpoint outstanding (`report/integration_guide.md`).

## `TODO(mac)` / `TODO(confirm)` index

```
grep -rn "TODO(mac)\|TODO(confirm)\|TODO(P5)" Sources BenchApp flutter scripts
```

## Open questions (規劃書 §12 待你確認)

1. Which iPhones for testing?
2. Production backend prescan `stride / min_height / buffer_sec / max_gap_sec`?
3. Convert an FP32 Core ML HRNet in P0 (clean 3-way accuracy split)?
4. Integration direction: 2D on-device + upload keypoints, rest on server — confirmed?
5. Who builds the backend `/analyze/keypoints` endpoint, and when?
6. App bundle size ceiling (HRNet ≈ 120 MB — on-demand download?)?
7. Add Apple Vision to the detector picker alongside `yolo26{n,s,m,l}`?
