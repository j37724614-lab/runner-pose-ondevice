# IOSurface Memory Diagnosis

此文件整理目前 Runner Pose on-device pipeline 的處理流程，以及 Instruments 看到 `VM: IOSurface Persistent = 3.65 GiB / # Persistent = 563` 時，最可能造成大量影像記憶體壅塞的原因。

## 觀察重點

目前觀察到：

| 指標 | 數值 | 解讀 |
|---|---:|---|
| `VM: Stack` | 4.92 MiB | Swift / thread stack 不是主要問題 |
| `VM: IOSurface Persistent` | 3.65 GiB | 大量影像 buffer 仍被系統或 framework 持有 |
| `# Persistent` | 563 | 同時或短時間內累積了數百個 IOSurface-backed buffer |

這代表問題比較不像一般 Swift object / array 記憶體暴增，而是 `CVPixelBuffer`、Core Image、Core ML、AVFoundation、VideoToolbox 或 `AVAssetWriterInputPixelBufferAdaptor` 相關的 IOSurface-backed image buffer 被保留太久、排隊太深，或沒有被 pool / back-pressure 限制住。

粗估大小：

| Buffer 類型 | 尺寸 | 每張約略大小 |
|---|---:|---:|
| 1920x1080 BGRA source frame | 1920 × 1080 × 4 | 7.9 MiB |
| 1280x720 BGRA source frame | 1280 × 720 × 4 | 3.5 MiB |
| HRNet crop | 288 × 384 × 4 | 0.42 MiB |
| HRNet heatmap | 1 × 23 × 96 × 72 × 4 | 0.61 MiB |

`3.65 GiB / 563 ≈ 6.6 MiB`，這個平均大小接近 720p 到 1080p 的 BGRA video frame，而不是 288×384 crop。因此首要懷疑對象應該是 source frame / export output frame 的 IOSurface，而不是 HRNet crop pool 或 heatmap。

## 目前處理 Flow

### A. 分析階段

```text
Video file
  -> S0 PrescanFilter.scan
       AVAssetReader 逐幀讀影片
       每 prescanStride 幀把 CVPixelBuffer 丟給 YOLO
       產生 hitFrames
       merge 成 valid frame ranges

  -> S1 VideoFrameReader.frames
       AVAssetReaderTrackOutput 輸出 BGRA CVPixelBuffer
       kCVPixelBufferIOSurfacePropertiesKey: [:]
       alwaysCopiesSampleData = false
       透過 AsyncThrowingStream yield DecodedFrame

  -> S2 PersonDetector.detect
       YOLO26Detector 使用 CIImage(cvPixelBuffer: frame)
       UltralyticsYOLO / Core ML / Vision path 執行 detect
       選出 runner bbox

  -> S3 CropWarp.makeCrop
       從 CVPixelBufferPool 取 288x384 BGRA crop
       vImageAffineWarp_ARGB8888 做 affine crop

  -> S4 HRNetRunner.predict
       Core ML HRNet 推論
       outputBackings 重用 reusableOutput MLMultiArray

  -> S5 HeatmapDecoder.decode
       從 heatmap 解 23 個 keypoints
       只保存 RunnerPose metadata
```

主分析階段理想上應該只有少量 frame 同時存活：目前 `PosePipeline.run` 是 sequential loop，一次處理一個 `DecodedFrame`，`RunnerPose` array 只保留 bbox / joints / timestamp，不保留 image buffer。

### B. HRNet overlay 輸出階段

```text
lastPoses
  -> RunnerPoseVideoExporter.exportOverlayVideo
       重讀 source video
       對 valid frame 建立新的 output CVPixelBuffer
       CIContext.render(sourceBuffer -> outputBuffer)
       CGContext 畫 bbox / skeleton
       adaptor.append(outputBuffer)
       寫成 mp4
```

此階段每個輸出 frame 目前使用 `CVPixelBufferCreate` 重新配置 full-size BGRA output buffer。這些 buffer 也是 IOSurface-backed，而且 append 給 `AVAssetWriterInputPixelBufferAdaptor` 後，writer / encoder 可能會保留數個甚至大量 frame，直到編碼端消化完成。

### C. Prescan bbox overlay 輸出階段

```text
source video
  -> collectPrescanOverlays
       另外建立 detector
       重讀 source video
       每 stride 幀 detect
       保存 Detection metadata

  -> exportPrescanOverlayVideo
       再重讀 source video
       valid range frame 建立新的 output CVPixelBuffer
       CIContext.render + CGContext draw
       adaptor.append(outputBuffer)
```

這條路徑會多建立一個 detector instance，且同樣逐幀配置 full-size output buffer。若剛跑完分析又立刻 export，模型、decoder surface、writer surface 可能會在同一段時間內重疊存在。

## IOSurface 來源盤點

| 來源 | 程式位置 | 是否 IOSurface-backed | 風險 |
|---|---|---:|---|
| Source decode frame | `VideoFrameReader.frames` | 是 | 高 |
| Prescan decode frame | `PrescanFilter.scan` | 可能由 decoder/framework 決定 | 中 |
| YOLO input path | `YOLO26Detector.detect` 的 `CIImage(cvPixelBuffer:)` | 使用 source surface | 高 |
| HRNet crop | `CropWarp` 的 `CVPixelBufferPool` | 是 | 低到中 |
| HRNet warmup dummy crop | `HRNetRunner.blankCrop` | 是 | 低 |
| Overlay source decode frame | `RunnerPoseVideoExporter` reader | 是 | 高 |
| Overlay output frame | `RunnerPoseVideoExporter.makePixelBuffer` | 是 | 很高 |
| AVAssetWriter adaptor / encoder queue | `AVAssetWriterInputPixelBufferAdaptor.append` | 是 | 很高 |

## 最可能原因排序

### 1. `AsyncThrowingStream` 沒有嚴格 back-pressure

`VideoFrameReader.frames` 目前在 `AsyncThrowingStream` 裡開一個 `Task`，reader loop 會持續 `copyNextSampleBuffer()` 並 `continuation.yield(...)`。

如果 decode / stream producer 比 YOLO + HRNet consumer 快，`AsyncThrowingStream` 可能暫存多個 `DecodedFrame`。每個 `DecodedFrame` 都持有 source `CVPixelBuffer`，而 source buffer 是 full-size IOSurface。

這和目前現象相符：

- Swift stack 很小。
- `RunnerPose` array 沒有保存 image。
- IOSurface 數量很多，平均大小接近 full-size frame。

建議優先修正：把 `VideoFrameReader.frames` 改成真正 pull-based API，例如 `forEachFrame(url:in:_:) async throws`，在同一個 loop 中「讀一幀 -> await 下游處理完 -> 下一幀」。若仍要保留 stream，至少要使用 `.bufferingNewest(1)` 或 `.bufferingOldest(1)`，但 pose pipeline 不適合丟幀，所以 pull-based 比較正確。

### 2. Overlay export 每幀 `CVPixelBufferCreate` full-size output buffer

`RunnerPoseVideoExporter.makePixelBuffer` 每次 append 都建立新的 BGRA output buffer。Full HD 一張約 7.9 MiB，若 writer / encoder queue 累積幾百張，就會直接到數 GiB。

`while !writerInput.isReadyForMoreMediaData` 只能避免 writer input 明確回報不能收資料，但不等於 append 後 output buffer 立刻釋放。encoder 可能仍持有已 append 的 IOSurface。

建議優先修正：

1. 使用 `AVAssetWriterInputPixelBufferAdaptor.pixelBufferPool` 建立 output buffer。
2. 每次從 adaptor pool 取 buffer，而不是直接 `CVPixelBufferCreate`。
3. 在 append loop 內包 `autoreleasepool`，縮短 Core Image / Core Graphics 暫存物件生命週期。
4. 必要時降低輸出解析度或改成分段輸出驗證。

### 3. YOLO / Core Image 對 source CVPixelBuffer 可能延後使用

`YOLO26Detector.detect` 使用：

```swift
let result = yolo(CIImage(cvPixelBuffer: frame))
```

`CIImage` 是 lazy image recipe，不一定在建立當下就複製或完成處理。UltralyticsYOLO 內部如果非同步提交到 GPU / Core ML，可能暫時保留 source IOSurface。當 upstream stream 又繼續 yield frame，就會疊加。

建議：

- 先解決 reader back-pressure。
- 若仍高，檢查 UltralyticsYOLO 是否有內部 frame queue / predictor cache。
- 在 detect 呼叫外層加局部 `autoreleasepool`，觀察 IOSurface 是否下降。

### 4. Prescan / processing / export 連續執行造成峰值重疊

一次完整操作可能包含：

```text
分析 prescan
分析 processing
HRNet overlay export
Prescan bbox overlay export
```

其中 prescan export 又會額外建立 detector 並重讀影片。若前一階段的 AVFoundation / Core ML / Core Image 資源還沒完全釋放，下一階段立刻開始，Instruments 可能看到多組 IOSurface 同時 persistent。

建議：

- 分開量測：只跑 analyze、不 export；只跑 HRNet export；只跑 prescan export。
- 每段完成後等待數秒，看 Persistent IOSurface 是否回落。
- 確認 UI 不會在同一時間啟動兩個 export task。

### 5. `CVPixelBufferPool` 本身不是主要嫌疑，但需要限制上限

`CropWarp` pool minimum count 是 4，單張 288×384 BGRA 約 0.42 MiB。即使 pool 留 4 到 10 張，也只是數 MiB，不足以解釋 3.65 GiB。

不過未來若做 bounded-parallel pipeline，仍應把 pool size 和 pipeline depth 對齊，避免 pool 動態增長。

## 建議排查順序

| 優先 | 動作 | 目的 | 預期結果 |
|---:|---|---|---|
| 1 | 只跑 analyze，不按 export | 分離主 pipeline 與輸出階段 | 若 IOSurface 仍高，優先查 reader / YOLO |
| 2 | analyze 完等待 10 秒再看 IOSurface | 看 framework 暫存是否自然釋放 | 若下降，偏向短期峰值；若不降，偏向持有或 queue |
| 3 | 只跑 HRNet overlay export | 驗證 writer output buffer 是否主因 | 若快速累積，修 adaptor pool |
| 4 | 只跑 prescan bbox export | 驗證額外 detector + export 是否疊加 | 若比 HRNet export 高，查 collectPrescanOverlays |
| 5 | 把 `VideoFrameReader` 改成 pull-based | 消除 stream queue | 分析階段 IOSurface 數量應接近固定 |
| 6 | overlay output 改 adaptor pool + autoreleasepool | 限制 encoder output frame 配置 | export 階段 Persistent 數量應下降 |

## 建議修改方向

### P0：先修主 pipeline back-pressure

新增 sequential reader API：

```swift
static func forEachFrame(
    url: URL,
    in ranges: [PrescanFilter.FrameRange],
    _ body: (DecodedFrame) async throws -> Void
) async throws
```

然後 `PosePipeline.run` 改成：

```swift
try await VideoFrameReader.forEachFrame(url: url, in: prescanResult.ranges) { frame in
    // 原本 for try await frame loop 的內容
}
```

這樣 `copyNextSampleBuffer()` 不會跑在另一個 producer task 裡，下一張 frame 只有在目前 frame 的 YOLO / warp / HRNet / decode 都完成後才會讀取。

### P1：修 overlay export buffer 配置

把目前：

```swift
guard let outputBuffer = makePixelBuffer(width: Int(frameSize.width), height: Int(frameSize.height)) else { ... }
```

改成從 `adaptor.pixelBufferPool` 取：

```swift
guard let pool = adaptor.pixelBufferPool else { ... }
var outputBuffer: CVPixelBuffer?
CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
```

並在每幀 append 外層使用 `autoreleasepool` 控制 `CIImage`、Core Graphics、Core Image render 暫存物件。

### P2：把 frameSet 改成 range cursor

`VideoFrameReader.frameSet(_:)` 會把 ranges 展開成 `Set<Int>`。這不是 IOSurface 3.65 GiB 的主因，但長影片會增加 metadata memory。可以參考 exporter 的 `advanceRangeIndex`，用 range cursor 判斷 frame 是否在 valid range。

### P3：加入 memory signpost / log

在以下位置記錄 footprint 與 frame index：

- prescan 每 30 sampled frames
- processing 每 30 processed frames
- export 每 30 appended frames
- `writerInput.isReadyForMoreMediaData` 等待前後
- `adaptor.append` 失敗或成功後

這能判斷 memory 是在 decode、YOLO、HRNet 還是 writer append 後累積。

## 初步結論

目前 `VM: IOSurface Persistent = 3.65 GiB` 最合理的解釋是 full-size video `CVPixelBuffer` 累積，而不是 Swift stack 或 HRNet heatmap。平均每個 persistent surface 約 6.6 MiB，和 source / output video frame 大小吻合。

最需要優先處理的兩個點：

1. `VideoFrameReader.frames` 改成 pull-based sequential reader，避免 `AsyncThrowingStream` 隱性排隊 full-size source frames。
2. `RunnerPoseVideoExporter` 改用 `AVAssetWriterInputPixelBufferAdaptor.pixelBufferPool`，避免 export 時每幀直接配置 full-size IOSurface，並降低 writer / encoder queue 造成的 persistent surface 峰值。

完成這兩項後，再重新用 Instruments 分別測 analyze、HRNet overlay export、prescan bbox export。若 IOSurface 仍維持數 GiB，下一步再深入查 UltralyticsYOLO / Core Image 是否保留 source surfaces。