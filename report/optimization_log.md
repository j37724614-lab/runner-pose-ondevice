# optimization_log.md

One row per optimisation commit (規劃書 §04 / §05 P2). Measure before/after on the
main device, same video, same compute unit, 15 runs / 3 warmup.

| # | commit | change | total ms | hrnet μ ms | eff. FPS | peak MB | keypoint Δ px | notes |
|---|--------|--------|----------|------------|----------|---------|---------------|-------|
| 0 | (P1) | naive sequential baseline | — | — | — | — | 0 (reference) | |
| 1 | | `.mlmodelc` cached compile | | | | | 0 | cold start only |
| 2 | | `outputBackings` reuse | | | | | 0 | |
| 3 | | `warmUp()` dummy predict | | | | | 0 | first-frame outlier gone |
| 4 | | `CVPixelBufferPool` for crops | | | | | 0 | memory curve |
| 5 | | zero-copy frame path (`alwaysCopiesSampleData=false`, IOSurface input) | | | | | 0 | |
| 6 | | bounded-parallel pipeline (depth 3) | | | | | 0 | **headline** |
| 7 | | vDSP DarkPose | | | | | ≤ ε | vs naive loops |
| 8 | | detector cadence 6 + extrapolation | | | | | **measure** | §07 sweep |
| 9 | | (optional) Metal DarkPose | | | | | ≤ ε | only if profiled bottleneck |

Rule: any row with `keypoint Δ px` above the §09 warn band is reverted or gated.
