# Runner Pose On-Device Memory Layout

此文件記錄目前專案的記憶體配置做法，重點是避免每 frame 反覆配置大型 buffer、避免影像格式來回 copy，並盡量讓 Core ML / Vision / vImage 直接處理 `CVPixelBuffer`。

## 總覽

```
Video file
  ↓ AVAssetReaderTrackOutput
DecodedFrame(pixelBuffer: CVPixelBuffer)
  ↓ YOLO / Vision detector
Detection[] / BBox
  ↓ CropWarp
Pooled 288×384 CVPixelBuffer crop
  ↓ HRNet MLModel
Reusable MLMultiArray heatmaps
  ↓ HeatmapDecoder
RunnerPose(bbox + joints only)
```

目前主路徑沒有把 frame 轉成 `UIImage` / `CGImage` 再轉回來，也沒有把每一幀的 `CVPixelBuffer` append 到陣列長期保存。

## 模型生命週期

| 模型 | 目前做法 | 記憶體意義 |
|---|---|---|
| YOLO26 | `YOLO26Detector` 持有 `private var yolo: YOLO?`，第一次 `loadYOLO()` 後 cache | 不會每 frame 重新建立 YOLO model |
| HRNet | `HRNetRunner` 持有 `private let model: MLModel` | 不會每 frame 重新建立 HRNet model |
| HRNet compiled model | `.mlpackage` 會 compile 成 `.mlmodelc` 並 cache 到 user caches | 避免每次 app 啟動都重新 compile |
| Engine | `RunnerPoseEngine` actor 持有一組 detector / HRNet / CropWarp / decoder | 一次 run 期間模型與 buffer owner 穩定存在 |

會重新建立模型的情況：

- 第一次建立 `RunnerPoseEngine`
- 呼叫 `RunnerPoseEngine.reconfigure(_:)`
- 另外跑 prescan overlay export 時，`RunnerPoseVideoExporter.exportPrescanOverlayVideo` 會建立自己的 detector
- 模型檔或 cache 被刪除後，HRNet 可能重新 compile

## Source Frame Buffer

`VideoFrameReader` 使用：

- `AVAssetReaderTrackOutput`
- `kCVPixelFormatType_32BGRA`
- `kCVPixelBufferIOSurfacePropertiesKey`
- `alwaysCopiesSampleData = false`

這代表 source frame 盡量以 IOSurface-backed `CVPixelBuffer` 形式從 decode 階段往下傳，不先轉成 `UIImage`、`CGImage` 或 `MLMultiArray`。

目前風險：

| 風險 | 說明 | 建議 |
|---|---|---|
| `AsyncThrowingStream` 隱性 buffering | `VideoFrameReader.frames` 是 push-based。若 reader 比 downstream YOLO/HRNet 快，stream 可能暫存多個 `DecodedFrame`，也就是多個 `CVPixelBuffer` | 改成 pull-based reader 或 `forEachFrame` sequential API |
| frameSet 記憶體 | `frameSet(_:)` 會把 prescan ranges 展開成 `Set<Int>` | 對短片影響小；長片和大範圍可改成 range cursor |
| 尚未 per-range seek | 現在讀整條 track，再用 index 過濾 | kept ratio 很低時會有額外 decode / I/O 成本 |

## Crop Buffer

`CropWarp` 目前建立一個 `CVPixelBufferPool`：

| 設定 | 目前值 |
|---|---|
| Pixel format | BGRA |
| Width | `config.hrnetInputWidth = 288` |
| Height | `config.hrnetInputHeight = 384` |
| IOSurface-backed | yes |
| Metal compatibility | yes |
| Minimum buffer count | 4 |

每個 valid frame 會從 pool 取一個 288×384 crop buffer：

```
source CVPixelBuffer + BBox
  ↓ vImageAffineWarp_ARGB8888
pooled crop CVPixelBuffer
```

這比每 frame 手動配置新 image object 更好，也避免 `UIImage` / `CGImage` 中間格式。

目前風險：

- pool minimum count 是 4，但目前 pipeline 是 sequential baseline，理論上不需要太多 crop 同時存活。
- 未來若做 bounded-parallel pipeline，pool size 要和 pipeline depth 對齊，避免 pool 動態增長造成記憶體峰值不穩。

## HRNet Output Buffer

`HRNetRunner` 目前有：

```swift
private var reusableOutput: MLMultiArray
```

每次 prediction 使用：

```swift
options.outputBackings = ["heatmaps": reusableOutput]
```

HRNet heatmap shape：

| 維度 | 值 |
|---|---|
| Batch | 1 |
| Joints | 23 |
| Height | 96 |
| Width | 72 |
| Data type | Float32 |

約略大小：

```
1 × 23 × 96 × 72 × 4 bytes ≈ 636 KB
```

這個 output buffer 會重複使用，避免每 frame 都分配新的 heatmap `MLMultiArray`。

注意：`predict(crop:)` 註解已寫明「consume it before the next call」。因為 output buffer 會重用，後處理必須在下一次 HRNet prediction 前完成。現在 sequential pipeline 符合這個條件。

## Result Memory

主 pipeline 會累積：

| 資料 | 儲存位置 | 內容 | 記憶體風險 |
|---|---|---|---|
| `poses` | `PosePipeline.run` | `RunnerPose` array | 低，只有 bbox / joints / timestamp |
| `rows` | `PosePipeline.run` | per-frame benchmark CSV rows | 低到中，長影片會增加 |
| `lastPoses` | BenchApp `BenchRunner` | 上次 run 的 poses，用於 overlay export | 低，沒有 image buffer |
| `reports` | `BenchResultStore` | benchmark report history | 低 |
| `MemorySampler.samplesMB` | `MemorySampler` | 每 250 ms 記錄 footprint | 低 |

目前沒有發現：

```swift
frames.append(CVPixelBuffer)
images.append(UIImage)
images.append(CIImage)
images.append(CGImage)
results.append(largeImageResult)
```

## Overlay Export Memory

`RunnerPoseVideoExporter` 的策略是重新讀原始影片、逐幀畫 overlay、逐幀寫出。

優點：

- pipeline 主分析階段不需要保存原始 frame。
- `RunnerPose` 只保存座標，記憶體壓力低。

成本：

- export 需要再做一次 video decode。
- output frame buffer 會逐幀配置；可接受，但未來可考慮 output pixel buffer pool。

Prescan bbox overlay 也會另外跑一次 detector，這代表會多建立一個 detector instance，不是主 pipeline 的模型重用路徑。

## 目前符合的原則

| 原則 | 是否符合 | 說明 |
|---|---|---|
| 模型不要每 frame 重建 | 是 | YOLO / HRNet 都 cache |
| 避免 `UIImage` / `CGImage` 中間轉換 | 是 | 主路徑以 `CVPixelBuffer` 為核心 |
| crop buffer 重用 | 是 | `CVPixelBufferPool` |
| HRNet output 重用 | 是 | `MLPredictionOptions.outputBackings` |
| 不長期保存 frame image | 基本符合 | 沒有手動 append image buffer；但 `AsyncThrowingStream` 可能隱性暫存 |
| 嚴格 back-pressure | 尚未完全符合 | `AsyncThrowingStream` 不是嚴格 pull-based |
| 長片 metadata streaming | 尚未完全符合 | `poses` / `rows` 目前全量累積 |

## 主要記憶體風險排序

1. `VideoFrameReader.frames` 的 `AsyncThrowingStream` 可能讓 `CVPixelBuffer` 排隊暫存。
2. `frameSet(_:)` 將 valid ranges 展開成 `Set<Int>`，長影片可改成 range cursor。
3. 未來 bounded-parallel pipeline 若沒有固定 depth，crop buffers / heatmaps / source frames 可能同時存活過多。
4. Overlay export 目前逐幀配置 output buffer，長時間 export 可能有配置抖動。
5. `poses` / `rows` 對一般影片問題不大，但超長影片可改 streaming persistence。

## 建議改善順序

1. 將 `VideoFrameReader` 改成 pull-based sequential reader，確保下游處理完才讀下一幀。
2. 用 range cursor 取代 `frameSet(_:)`，避免長影片把所有 frame index 展開到 Set。
3. 若做 P2 bounded-parallel pipeline，明確設定 pipeline depth，並讓 `CVPixelBufferPoolMinimumBufferCountKey` 跟 depth 對齊。
4. Overlay export 加 output `CVPixelBufferPool`，減少逐幀配置。
5. 長影片模式下將 `rows` streaming 寫 CSV，`poses` 只依需求保存 overlay 所需範圍。
