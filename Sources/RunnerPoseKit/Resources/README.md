# Resources — Core ML models (not in git)

`.mlpackage` files are large binaries and are `.gitignore`d. Place them here **on the Mac**
before `swift build` / opening BenchApp.

**Easiest:** run `scripts/fetch_models.sh` from the repo root — it downloads the YOLO
`.mlpackage`s, copies the HRNet model from `runner-analysis-pipeline` (or `HRNET_URL=`),
stages everything into this folder, and keeps a copy under `models/`. See
`models/README.md` for the full manifest. The manual steps below are the fallback.

| File | Source | Notes |
|---|---|---|
| `HRNetRunnerWholeBody23.mlpackage` | `runner-analysis-pipeline/models/coreml/` | the trained model; FP16. Optionally also `HRNetRunnerWholeBody23FP32.mlpackage` (`--precision float32`) for the §07 three-way accuracy split |
| `yolo26n.mlpackage` | [yolo-ios-app v8.3.0 release](https://github.com/ultralytics/yolo-ios-app/releases/tag/v8.3.0) `yolo26n.mlpackage.zip` | detector candidate |
| `yolo26s.mlpackage` | same release, `yolo26s.mlpackage.zip` | detector candidate |
| `yolo26m.mlpackage` | same release, `yolo26m.mlpackage.zip` | detector candidate |
| `yolo26l.mlpackage` | same release, `yolo26l.mlpackage.zip` | detector candidate — default |

```bash
# from the release page, per scale:
curl -L -o yolo26n.mlpackage.zip \
  https://github.com/ultralytics/yolo-ios-app/releases/download/v8.3.0/yolo26n.mlpackage.zip
unzip yolo26n.mlpackage.zip -d .
```

**BenchApp** bundles all four YOLO scales so the §08 先導 sweep can switch between them
on the phone. The **production `RunnerPoseKit`** should keep only the scale picked after
that sweep (規劃書 §08 / §12) — trim this folder and `DetectorModel` before shipping into
the main app.

The YOLO `.mlpackage`s here are also consumed through the `UltralyticsYOLO` SwiftPM
dependency's loader; see `PersonDetector.swift` `TODO(mac)`.
