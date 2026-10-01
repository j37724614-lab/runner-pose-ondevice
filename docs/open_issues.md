# Runner Pose On-Device Open Issues

此文件整理目前尚未完成、需要驗證、或已知仍有風險的項目。優先順序以「會影響正確性或跑者 bbox 穩定度」放前面。

## P0：Correctness / Accuracy

| 項目 | 目前狀態 | 影響 | 建議處理 |
|---|---|---|---|
| `boxToCenterScale` aspect ratio quirk | 目前沿用上游 Python 行為：`frameHeight / frameWidth`，不是 HRNet input `288 / 384` | 可能影響 crop 範圍與 keypoint 座標，但為了 parity 暫時保留 | 用 checkerboard fixture 和真實 heatmap 跑 parity；確認後再決定是否修正 Swift 與 Python |
| vImage warp direction | `CropWarp.swift` 註解標記需確認 `vImageAffineWarp_ARGB8888` transform 方向 | 若方向錯，HRNet crop 會偏移或翻轉 | 加幾何 fixture，比對 OpenCV `warpAffine` |
| DarkPose Gaussian border / cv2 parity | `HeatmapDecoder.swift` 仍有 TODO 需對真實 heatmap 確認 | 可能造成關節點 0.x 到數 px 偏差 | 用 `DarkPoseParityTests` 對真實 fixture 比對 Python |
| Output schema frozen fixture | `OutputSchemaTests` 存在，但仍需用正式 keypoint fixture 鎖定 | Flutter/backend 串接時可能格式漂移 | 產生固定 pipeline output fixture 並納入測試 |
| YOLO L 主跑者選擇 | 已加入 `trackerMinIoU` 與中心距離 fallback | 仍可能在第一幀選到背景中最高的人 | 下一步加入 ROI 或使用者初始點選主跑者 |
| `minBoxHeight` production value | 目前預設 `40 px`，標記 `TODO(confirm)` | 太低會抓背景，太高會漏遠處跑者 | 從 production backend 或測試集統計取得正式值 |

## P1：Memory / Frame Pipeline
ａ
| 項目 | 目前狀態 | 影響 | 建議處理 |
|---|---|---|---|
| `VideoFrameReader.frames` 使用 `AsyncThrowingStream` | 目前是 push-based stream，可能隱性暫存多個 `CVPixelBuffer` | 長影片或 HRNet 較慢時，記憶體峰值可能上升 | 改成 pull-based reader，或提供 `forEachFrame` sequential API |
| Per-range seeking 尚未實作 | 現在讀整條 track，再用 frame index 過濾 prescan ranges | kept ratio 很低時仍會掃過大量無效 frame | 用 `AVAssetReader.timeRange` 逐 range 讀取並 benchmark |
| Decode per-frame timing | `PosePipeline.row` 目前 `decodeMs = 0` | BenchReport 無法拆出 S1 decode 成本 | 在 reader 或 pull API 中回報 decode timing |
| `poses` / `rows` 全量累積 | pipeline run 會累積所有 `RunnerPose` 與 per-frame CSV row | 不是影像資料，風險小；超長影片仍會增加 metadata memory | 長影片模式改成 streaming persist，只保留 summary 與必要 overlay poses |
| Overlay export 重新讀影片 | 目前輸出 overlay 會重讀 source video | 記憶體較省，但多一次 I/O 與 decode 成本 | 保留此策略；若要加速，需明確限制 frame buffer cache 大小 |

## P2：Performance Optimization

| 項目 | 目前狀態 | 影響 | 建議處理 |
|---|---|---|---|
| Bounded-parallel pipeline | `PosePipeline` 仍是 sequential baseline | 無法充分重疊 decode / detect / warp / HRNet / postprocess | 實作 bounded channel，深度從 2 或 3 開始 |
| vDSP DarkPose | 目前後處理仍是 Swift baseline | postprocess 可能成為非 ANE 瓶頸 | 先 profile，若 postprocess 明顯再改 vDSP |
| Optional Metal DarkPose | 未開始 | 只有在 vDSP 仍不足時才有價值 | 當 profile 證明 bottleneck 後再做 |
| Detector cadence sweep | UI 可調 cadence，但正式矩陣未填 | 不知道 YOLO N/S/M/L 與 cadence 的準確率/速度 tradeoff | 用同一影片跑 `yolo26n/l` cadence 1/3/6，填 `report/performance.md` |
| YOLO L thresholds | 已下載 `yolo26l`，`detectorConf` 改為 `0.45` | 還沒用資料集驗證最佳 threshold | 掃 `0.35 / 0.45 / 0.55`，比較 bbox miss 與 false positive |

## P3：Benchmark / Reports

| 項目 | 目前狀態 | 影響 | 建議處理 |
|---|---|---|---|
| `report/performance.md` 還是 template | 尚未填 device、latency、FPS、memory | 無法判斷是否達到正式門檻 | 從 BenchApp export 與 `bench_delta.py` 填表 |
| `report/optimization_log.md` 未填測量值 | 目前只有預期優化項目 | 無法追蹤每次改動效果 | 每次性能改動後補 commit、FPS、peak MB、keypoint delta |
| Device inventory 未填 | iPhone 型號、iOS、RAM、角色未記錄 | benchmark 不可重現 | 先填主測裝置與低階裝置 |
| Acceptance verdict 未填 | §09 targets 尚無 result | 無法判定能否整合到主 app | 補 mean error、PCK、peak memory、thermal |

## P4：Flutter / Backend Integration

| 項目 | 目前狀態 | 影響 | 建議處理 |
|---|---|---|---|
| Flutter plugin skeleton | `flutter/runner_pose` 存在，但 Pigeon messages 尚未完成 | Flutter app 還不能穩定呼叫 RunnerPoseKit | 定義 analyze API、progress callback、error mapping |
| iOS plugin implementation | `RunnerPosePlugin.swift` 尚需接完整 `RunnerPoseEngine` | 主 app 還不能使用 on-device pose | 實作 path input、config options、JSON output |
| Backend `/analyze/keypoints` | 不在本 repo，仍是待辦 | 無法只上傳 keypoints 取代影片 | 後端新增 precomputed 2D keypoints path |
| Keypoints payload contract | 文件已有草案，但未用測試鎖定 | 前後端容易不一致 | 用 fixture 測 `toKeypointsPayload` 與 server parser |
| Feature flag / A-B path | 尚未整合 | 無法安全比較 server 舊流程與 on-device 新流程 | 主 app 保留 video upload 與 keypoints upload 雙路徑 |

## P5：Docs / Stale Notes

| 項目 | 目前狀態 | 影響 | 建議處理 |
|---|---|---|---|
| `docs/PLAN.md` 狀態過期 | 仍寫 `YOLO detect + warmUp TODO(mac)`，但目前已接 UltralyticsYOLO | 文件會誤導後續開發 | 更新 P1 狀態 |
| `Sources/RunnerPoseKit/Resources/README.md` 過期 | 仍提到 `PersonDetector.swift TODO(mac)` | 文件與程式不同步 | 更新 model loading 說明 |
| `current_pipeline.md` S0 table 過期 | 表格仍寫 `detectorConf 0.25`，S2 已更新為 `0.45` | 閱讀者會混淆 prescan 與 runtime threshold | 統一所有文件中的 detectorConf |
| Known issues 未反映 YOLO L | 舊描述仍偏向調低 threshold 或換大模型 | 現在問題是 YOLO L false positive 與主跑者 selection | 補 YOLO L 選框策略與剩餘風險 |

## 建議下一步

1. 先做 `VideoFrameReader` pull-based sequential reader，降低 `CVPixelBuffer` 隱性 buffering 風險。
2. 補 `CropWarp` 與 `HeatmapDecoder` parity fixtures，先保證座標正確。
3. 用同一支影片跑 YOLO N/L、`detectorConf 0.35/0.45/0.55`、cadence 1/3/6，填 `performance.md`。
4. 若 YOLO L 仍選錯背景人物，加入主跑者 ROI 或第一幀手動選人。
5. 更新過期文件，避免 `TODO(mac)` 和目前程式狀態衝突。
