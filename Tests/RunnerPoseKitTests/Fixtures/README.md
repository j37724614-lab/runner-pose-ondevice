# Test fixtures (not in git)

Generated on the machine with a working `runner-analysis-pipeline` + its torch/HRNet env:

```bash
cd runner-pose-ondevice
python scripts/dump_parity_fixtures.py \
  --pipeline-root ../runner-analysis-pipeline \
  --video ../runner-analysis-pipeline/MotionAGFormer/demo/video/IMG_0033.MOV \
  --cases scripts/parity_cases.example.json \
  --out Tests/RunnerPoseKitTests/Fixtures
```

Each fixture `<name>` is:

| file | content |
|---|---|
| `<name>.crop.png` | 288×384 RGB crop the model saw |
| `<name>.heatmap.f32` | raw little-endian float32, shape `[23, 96, 72]`, row-major |
| `<name>.geometry.json` | `frame_size, bbox, center, scale, forward_affine_crop[6], inverse_affine_heatmap[6]` |
| `<name>.keypoints.json` | expected `23 × [x, y, score]` in **original frame pixels** (`get_final_preds_dark`) |
| `manifest.json` | list of fixtures |

`GeometryParityTests` and `DarkPoseParityTests` **skip themselves** (with a printed
note) when this folder is empty, so `swift test` is green before fixtures exist —
but the P1 acceptance gate is these tests passing (規劃書 §05 P1).

Acceptance: `DarkPoseParityTests` per-joint error < **0.5 px** vs these fixtures.
