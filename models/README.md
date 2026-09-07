# models/ — Core ML model staging area

Local staging copy of every model that `RunnerPoseKit` / `BenchApp` load. **Only this
README is tracked in git** — the model binaries are `.gitignore`d (規劃書 §02).

Populate with:

```bash
scripts/fetch_models.sh          # fetch all, then copy into Sources/RunnerPoseKit/Resources/
scripts/fetch_models.sh --no-stage   # only fill ./models/
```

## What the code loads

| File | Loaded by | Source | Size |
|---|---|---|---|
| `coreml/HRNetRunnerWholeBody23.mlpackage` | `Sources/RunnerPoseKit/Pipeline/HRNetRunner.swift` (`resourceName`) — S4 pose | our `runner-analysis-pipeline` (`scripts/tools/convert_hrnet_to_coreml.py`, FP16, iOS 15+) | ~122 MB |
| `coreml/HRNetRunnerWholeBody23.conversion.json` | contract reference (joint order, I/O shapes) — see `RunnerPose.swift`, `OutputSchemaTests.swift` | same | 1 KB |
| `yolo/yolo26{n,s,m,l}.mlpackage` | `Sources/RunnerPoseKit/Pipeline/PersonDetector.swift` (`YOLO26Detector`, via `UltralyticsYOLO`) — S0 prescan + S2 gate | [ultralytics/yolo-ios-app v8.3.0 release](https://github.com/ultralytics/yolo-ios-app/releases/tag/v8.3.0), `yolo26<scale>.mlpackage.zip` (COCO detect, INT8, 640, NMS-free) | n≈9 / s≈28 / m≈60 / l≈90 MB |
| `yolo/yolo26{n,s,m,l,x}.pt` | `scripts/make_prescan_reference.py` (Linux tooling, `ultralytics.YOLO`) — **not** an iOS model | ultralytics assets (also mirrored in `runner-analysis-pipeline/models/`) | 5–114 MB |

`yolo26x` / `HRNetRunnerWholeBody23FP32.mlpackage` are optional (規劃書 §07 accuracy
split, `yolo26x` heavy on ANE) — `DetectorModel` lists `yolo26x` but the default is
`yolo26n`.

## Notes

- The **`.pt`** files and the **`.mlpackage`** files are different artifacts. `.pt` =
  PyTorch weights for the desktop parity scripts; `.mlpackage` = compiled Core ML for
  the phone. Do not feed one where the other is expected.
- On the Mac, `swift build` picks the models up from
  `Sources/RunnerPoseKit/Resources/` (see `Package.swift` `.process("Resources")`),
  **not** from here. `fetch_models.sh` copies them across.
- Before shipping into the Flutter main app, trim to the single YOLO scale picked by
  the §08 先導 sweep (規劃書 §08 / §12).
