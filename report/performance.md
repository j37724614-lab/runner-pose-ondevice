# performance.md — template

Fill from `bench_delta.py` output + `BenchResultStore` export (規劃書 §04 / §06 / §09).
Format follows `ultralytics/yolo-ios-app` `docs/performance.md`.

## Device inventory

| device | chip / ANE gen | iOS | RAM | role |
|---|---|---|---|---|
| (fill) | | | | main |
| (fill) | | | | old-device floor |

## Isolated latency (Xcode Core ML Performance Report)

| model | device | compute | median ms | ANE op % |
|---|---|---|---|---|
| HRNet-W48 wb23 | | .all | | |
| HRNet-W48 wb23 | | .cpuAndNeuralEngine | | |

## In-app, per stage (optimized)

| device | compute | prescan (once) | decode | detect μ | warp μ | **hrnet μ/p90** | postproc μ | eff. FPS |
|---|---|---|---|---|---|---|---|---|
| | .cpuAndNeuralEngine | | | | | | | |

## naive → optimized (main device)

| metric | naive | optimized | Δ |
|---|---|---|---|
| effective FPS | | | |
| hrnet ms (p90) | | | |
| peak memory MB | | | |
| ANE utilisation % | | | |

## Detector selection (§08 先導, main device)

| model | cadence | detect μ ms | bbox IoU vs x | keypoint Δ px | .mlpackage MB |
|---|---|---|---|---|---|
| yolo26n | 1 | | | | |
| yolo26n | 6 | | | | |
| yolo26s | 6 | | | | |
| yolo26m | 6 | | | | |
| yolo26l | 6 | | | | |

**Chosen:** ____ — reason: ____

## Acceptance (§09)

| item | target | result | verdict |
|---|---|---|---|
| HRNet single-frame (ANE, in-app) | ≤ isolated × 1.5 | | |
| effective FPS | ≥ 15 | | |
| mean per-joint error vs Python | < 2 px | | |
| PCK@0.05 | > 0.95 | | |
| peak memory | < 400 MB (device-dependent) | | |
| long-video thermal | no `serious`, or latency +<30% | | |
