# RunnerAnalysisKit resources

Place the production MotionAGFormer Core ML package here on the Mac:

```text
MotionAGFormerLarge243.mlpackage
```

The expected interface is fixed by Step 17:

- input `pose2d_input`: float32 `[1, 243, 17, 3]`
- output `pose3d_output`: float32 `[1, 243, 17, 3]`
- H36M17 joint order
- iOS 16 minimum deployment target
- deterministic package hash (sorted file SHA-256 list):
  `a8acff3fa52397272e5ff21625d02cce80957931f9e455a7653031b4ec43c007`

The model package is intentionally ignored by git. `scripts/fetch_models.sh`
stages the verified conversion artifact from
`report/motionagformer_coreml/large_h36m/model.mlpackage` when it is present.
Because both locations are intentionally ignored by git, a fresh Mac checkout
must receive the package from a model release or a trusted local copy before the
Step 17 device test. A missing package produces an explicit skipped/degraded
pose3d stage; it never produces an empty successful 3D artifact.
