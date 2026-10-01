# IOSurface Memory Fix Log

此文件記錄本次依據 `iosurface_memory_diagnosis.md` 所做的程式修改。目標是降低 Instruments 中 `VM: IOSurface Persistent` 暴增的風險，尤其是 full-size video `CVPixelBuffer` 被 stream queue 或 video writer queue 長時間持有的情況。

## 修改目標

本次只處理兩個最高優先級項目：

| 優先 | 問題 | 修改方向 |
|---:|---|---|
| P0 | `VideoFrameReader.frames` 使用 `AsyncThrowingStream`，producer task 可能比下游 YOLO / HRNet 快，造成多張 source `CVPixelBuffer` 排隊 | 新增 pull-based sequential reader，讓 pipeline 處理完目前 frame 後才讀下一幀 |
| P1 | overlay export 每幀直接 `CVPixelBufferCreate` full-size output buffer，writer / encoder 可能保留大量 IOSurface | 改用 `AVAssetWriterInputPixelBufferAdaptor.pixelBufferPool` 分配 output buffer |

## 變更檔案

| 檔案 | 修改內容 |
|---|---|
| `Sources/RunnerPoseKit/Pipeline/VideoFrameReader.swift` | 新增 `forEachFrame(url:in:_:)`，提供 strict back-pressure 的 sequential frame reader |
| `Sources/RunnerPoseKit/Pipeline/PosePipeline.swift` | 主分析 loop 改用 `VideoFrameReader.forEachFrame`，不再透過 `AsyncThrowingStream` 讀 frame |
| `Sources/RunnerPoseKit/RunnerPoseVideoExporter.swift` | HRNet overlay export 與 prescan bbox export 改用 adaptor pixel buffer pool，並在 per-frame render/draw 區段加 `autoreleasepool` |

## 1. VideoFrameReader：新增 Pull-Based Reader

### 修改前

`VideoFrameReader.frames(url:in:)` 會建立 `AsyncThrowingStream`，並在 stream builder 內開一個 `Task`：

```swift
AsyncThrowingStream { continuation in
    let task = Task {
        while reader.status == .reading,
              let sample = output.copyNextSampleBuffer() {
            continuation.yield(DecodedFrame(...))
        }
    }
}
```

風險是 reader task 是 producer，下游 `PosePipeline` 是 consumer。如果 reader / decoder 比 YOLO + HRNet 快，stream 可能暫存多個 `DecodedFrame`。每個 `DecodedFrame` 都持有 full-size source `CVPixelBuffer`，這些 buffer 通常是 IOSurface-backed。

### 修改後

新增：

```swift
static func forEachFrame(
    url: URL,
    in ranges: [PrescanFilter.FrameRange],
    _ body: (DecodedFrame) async throws -> Void
) async throws
```

新的 reader 在同一個 caller task 裡執行：

```text
copyNextSampleBuffer()
  -> 建立 DecodedFrame
  -> await body(frame)
  -> body 完成後才讀下一張 sample
```

這樣 source frame 的生命週期會被下游處理節奏限制，不會因為 stream producer 先跑而排隊累積。

### 額外調整

`forEachFrame` 使用 range cursor 判斷 frame 是否落在 prescan valid ranges：

```swift
private static func isFrame(
    _ frameIndex: Int,
    in ranges: [PrescanFilter.FrameRange],
    rangeIndex: inout Int
) -> Bool
```

這避免在新路徑中把 ranges 展開成 `Set<Int>`。舊的 `frames(url:in:)` 與 `frameSet(_:)` 仍保留，避免其他呼叫點被破壞。

## 2. PosePipeline：改用 Sequential Reader

### 修改前

主處理流程使用：

```swift
for try await frame in VideoFrameReader.frames(url: url, in: prescanResult.ranges) {
    ...
}
```

### 修改後

改為：

```swift
try await VideoFrameReader.forEachFrame(url: url, in: prescanResult.ranges) { frame in
    ...
}
```

原本 `guard let box else { ... continue }` 在 closure 中改為 `return`，語意仍是「跳過目前 frame，繼續下一幀」。

### 影響

分析階段仍維持 sequential baseline，但 back-pressure 變嚴格：

```text
讀一幀
  -> detect
  -> warp
  -> HRNet
  -> postprocess
  -> append pose metadata
  -> 再讀下一幀
```

這是本次降低 source IOSurface 暫存量的主要修改。

## 3. RunnerPoseVideoExporter：改用 Writer Adaptor Pool

### 修改前

HRNet overlay export 與 prescan bbox export 都在每個 output frame 做：

```swift
guard let outputBuffer = makePixelBuffer(width: Int(frameSize.width), height: Int(frameSize.height)) else {
    throw RunnerPoseError.videoExportFailed("Cannot allocate output pixel buffer.")
}
```

原 helper 每次直接呼叫：

```swift
CVPixelBufferCreate(...)
```

這會為每張輸出 frame 配置新的 full-size BGRA `CVPixelBuffer`。若 writer / encoder 還沒消化完，這些 IOSurface 可能累積。

### 修改後

新增 pool-based helper：

```swift
private static func makePixelBuffer(
    from adaptor: AVAssetWriterInputPixelBufferAdaptor
) throws -> CVPixelBuffer
```

內部改為：

```swift
guard let pool = adaptor.pixelBufferPool else {
    throw RunnerPoseError.videoExportFailed("Cannot access output pixel buffer pool.")
}

var pixelBuffer: CVPixelBuffer?
let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
```

兩條 export path 都改用：

```swift
let outputBuffer = try makePixelBuffer(from: adaptor)
```

### Per-Frame Autorelease Pool

每幀的 Core Image render 與 Core Graphics draw 改包在：

```swift
autoreleasepool {
    ciContext.render(CIImage(cvPixelBuffer: sourceBuffer), to: outputBuffer)
    draw(...)
}
```

目的不是保證釋放 IOSurface，而是縮短 `CIImage`、Core Image render 中間物件、Core Graphics 暫存物件的 autoreleased lifetime，避免長時間 export 時暫存物件堆積。

## 修改後 Flow

### 分析階段

```text
AVAssetReader.copyNextSampleBuffer()
  -> DecodedFrame(source CVPixelBuffer)
  -> YOLO detect
  -> CropWarp pooled 288x384 crop
  -> HRNet reusable heatmap
  -> HeatmapDecoder
  -> RunnerPose metadata
  -> current frame scope ends
  -> next sample
```

關鍵變化：沒有獨立 producer task 預先 yield 多張 frame。

### Overlay Export 階段

```text
AVAssetReader source frame
  -> adaptor.pixelBufferPool 建立 / 重用 output buffer
  -> CIContext.render
  -> CGContext draw overlay
  -> adaptor.append
```

關鍵變化：output buffer 交由 writer adaptor pool 管理，不再每幀直接 `CVPixelBufferCreate`。

## 預期效果

| 階段 | 預期改善 |
|---|---|
| Analyze | source `CVPixelBuffer` 不應因 `AsyncThrowingStream` producer 預讀而大量排隊 |
| HRNet overlay export | output IOSurface allocation 應更受 writer adaptor pool 控制 |
| Prescan bbox export | 同樣降低逐幀直接配置 full-size output IOSurface 的風險 |
| Swift heap / stack | 不預期有明顯差異，因本次主要處理 VM / IOSurface |

## 驗證結果

已執行 Xcode build：

```text
BuildProject: The project built successfully.
```

單檔 diagnostics 也已確認：

| 檔案 | 結果 |
|---|---|
| `VideoFrameReader.swift` | No issues found |
| `PosePipeline.swift` | No issues found |
| `RunnerPoseVideoExporter.swift` | No issues found |

## 後續量測建議

建議用 Instruments 分三段測：

1. 只跑 analyze，不 export。
2. 只跑 HRNet overlay export。
3. 只跑 prescan bbox export。

每段觀察：

| 指標 | 觀察重點 |
|---|---|
| `VM: IOSurface Persistent` | 是否還會接近數 GiB |
| `# Persistent` | 是否仍維持數百個 surface |
| Memory Graph / Allocations | 是否有大量 `CVPixelBuffer` 或 Core Image object 長期存活 |
| analyze 完等待 10 秒 | IOSurface 是否自然下降 |

若本次修改後 analyze 階段已下降，但 export 階段仍高，下一步應檢查 `AVAssetWriter` / encoder queue 與輸出解析度。若 analyze 階段仍高，下一步應深入查 UltralyticsYOLO / Core Image 是否保留 source IOSurface。
