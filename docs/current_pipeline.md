# Runner Pose On-Device Pipeline — Data Flow

## 概覽

```
原始影片（磁碟）
    │
    ▼ S0  Prescan          ← YOLO 抽樣，找有跑者的幀範圍
    │
    ▼ S1  VideoFrameReader ← 只讀 prescan 有效幀，其餘 seek 跳過
    │
    ▼ S2  PersonDetector   ← 每幀跑 YOLO（cadence=1 預設）
    │
    ▼ S3  CropWarp         ← affine 裁切到 288×384
    │
    ▼ S4  HRNetRunner      ← Core ML 推論 → heatmap
    │
    ▼ S5  HeatmapDecoder   ← DarkPose decode → joint 像素座標
    │
    ├──▶ RunnerPose[]      ← per-frame 結果（含 valid:false gate-skip 幀）
    │
    ├──▶ BenchReport       ← 整體效能統計
    │
    └──▶ exportOverlayVideo() → 輸出影片（只含 prescan 有效幀）
```

---

## S0：Prescan（預掃描）

**目的：** 找出影片中跑者出現的幀範圍，讓後續管線完全跳過空白段。

**實作：** `PrescanFilter.scan(url:)`

| 參數 | 預設值 | 說明 |
|---|---|---|
| `prescanStride` | 8 | 每隔幾幀抽一幀送進 YOLO |
| `prescanBufferSec` | 1.0 s | 有效範圍前後各加的緩衝秒數 |
| `prescanMaxGapSec` | 1.0 s | 兩段 hit 之間允許的最大間隔（自動合併） |
| `detectorConf` | 0.25 | YOLO 信心度門檻 |
| `minBoxHeight` | 40 px | bbox 高度最小值（源像素） |

**流程：**
```
讀全片 → 每 stride 幀送 YOLO → 記錄 hitFrames[]
→ mergeHitFrames()
    ├─ 合併間距 ≤ maxGapFrames 的 hit
    ├─ 每段前後加 bufferFrames
    └─ 再次合併重疊段
→ [FrameRange] = [(startFrame, endFrame), ...]
```

**輸出：** `PrescanFilter.Result`
- `ranges: [FrameRange]` — 有效幀範圍
- `keptRatio` — 保留比例（kept / total）
- `elapsed` — 掃描耗時

---

## S1：VideoFrameReader（幀解碼）

**目的：** 只解碼 prescan 有效幀，無效段直接 seek 跳過，節省解碼時間。

**實作：** `VideoFrameReader.frames(url:in:[FrameRange])`

**輸出：** `AsyncStream<DecodedFrame>`
```swift
struct DecodedFrame {
    var pixelBuffer: CVPixelBuffer  // BGRA，IOSurface-backed
    var frameIndex: Int
    var timestamp: CMTime
    var frameSize: CGSize
}
```

---

## S2：PersonDetector（人體偵測）

**目的：** 每幀取得跑者的 bounding box。

**實作：** `YOLO26Detector` / `VisionHumanDetector`（由 `DetectorFactory.make` 工廠建立）

**cadence 機制（`PosePipeline.swift`）：**
```swift
let isDetectFrame = frame.frameIndex % config.detectorCadence == 0
    || tracker.coastedFrames >= config.trackerStalenessLimit
```

- `detectorCadence = 1`（預設）→ 每幀都跑 YOLO，無 gap
- `detectorCadence > 1` → 非偵測幀用 `BBoxTracker` 線性外插

**`pickRunner` 篩選條件（兩者皆需滿足）：**
1. `confidence >= detectorConf`（0.45）
2. `box.height >= minBoxHeight`（40 px）

**`pickRunner` 主跑者選擇策略：**
- 有 `tracker.lastBox` 時，先選 IoU 最大的候選框。
- 若最大 IoU `>= trackerMinIoU`（0.05），視為同一位跑者並採用該 bbox。
- 若 IoU 太低，改選中心點距離上一個 bbox 最近的候選框。
- 若最近候選框距離仍超過 `trackerMaxCenterDistanceRatio`（0.25）× 畫面對角線，回傳 `nil`，避免 track 跳到背景人物。
- 沒有 `tracker.lastBox` 時，維持原本策略：選高度最大的合格 bbox 作為初始主跑者。

**gate-skip：** YOLO 無結果或不過篩選 → `tracker.reset()` → 發出 `RunnerPose(valid:false, bbox:nil, joints:[])`

**輸出：** `BBox?`（源像素座標）

---

## S3：CropWarp（裁切與仿射變換）

**目的：** 將全幀 + bbox 變換為 HRNet 所需的 288×384 輸入圖。

**實作：** `CropWarp.makeCrop(from:box:frameSize:)`

**流程：**
```
boxToCenterScale(box, frameWidth, frameHeight)
    → center（bbox 中心）
    → scale（bbox 尺寸 / 200，再 ×1.25 加 25% 邊距）

affineTransform(center, scale, outputSize=288×384)
    → 前向仿射矩陣

vImageAffineWarp_ARGB8888(src, dst, forward)
    → 288×384 BGRA pixel buffer
```

> **注意（⚠️ 已知 quirk）：** `boxToCenterScale` 的 `aspectRatio` 計算使用 `frameHeight/frameWidth`（源幀比例），而非 HRNet 輸入比例 288/384。這是上游 Python pipeline 的原始行為，已原樣移植。

**輸出：** `(crop: CVPixelBuffer, info: WarpInfo)`
- `crop`：288×384 BGRA，送入 HRNet
- `info.center / .scale`：供 S5 做逆仿射

---

## S4：HRNetRunner（姿態推論）

**目的：** 對裁切後的人體圖執行 HRNet Core ML 模型，輸出 heatmap。

**實作：** `HRNetRunner.predict(crop:)`

**模型契約：**
- 輸入：288×384 RGB（normalization 已 bake 進模型）
- 輸出：72×96 heatmap（23 個關節）

**輸出：** heatmap tensor（shape: 23×96×72）

---

## S5：HeatmapDecoder（關節解碼）

**目的：** 從 heatmap 解出每個關節的像素座標（源幀空間）。

**實作：** `HeatmapDecoder.decode(heatmap:center:scale:)`

**流程：**
```
DarkPose sub-pixel decode（或 fastHeatmapDecode argmax + 局部精化）
    → heatmap 空間關節座標（72×96 內）
→ affineTransform(inverse:true)
    → 源幀像素座標
```

**輸出：** `[Joint]`（23 個）
```swift
struct Joint {
    var name: JointName
    var x, y: Double    // 源幀像素
    var score: Double   // heatmap 峰值信心度
}
```

---

## 管線輸出：RunnerPose

```swift
struct RunnerPose {
    var frameIndex: Int
    var timestamp: CMTime
    var bbox: BBox?         // nil → gate-skip（S2 未通過）
    var joints: [Joint]     // 空 → gate-skip
    var valid: Bool         // false → 此幀無骨架
    var bboxExtrapolated: Bool  // true → Tracker 外插（非 YOLO 新鮮偵測）
}
```

---

## 效能統計：BenchReport

每次 `analyze()` 結束產生一份 `BenchReport`，記錄：

| 欄位 | 內容 |
|---|---|
| `wallClockSeconds` | 總耗時 |
| `effectiveFPS` | poses.count / wall |
| `framesProcessed` | valid:true 幀數 |
| `framesSkippedByGate` | gate-skip 幀數 |
| `prescanKeptRatio` | prescan 保留比例 |
| `detectionFrames` | YOLO 新鮮偵測次數 |
| `extrapolatedFrames` | Tracker 外插次數 |
| `stages["prescan/detect/warp/hrnet/postproc"]` | 各階段 mean/p50/p90/max ms |
| `memory.peakMB` | 峰值記憶體 |
| `thermal` | 熱狀態轉換記錄 |

---

## 影片輸出：RunnerPoseVideoExporter

### HRNet overlay 影片

```
poses[] → validFrames = Set(poses.map { $0.frameIndex })

重新讀原始影片（第二次讀取）：
  frameIndex ∈ validFrames → 疊骨架 → 寫入（outputTime 順序累加）
  frameIndex ∉ validFrames → 丟棄

輸出：只含 prescan 有效幀，長度 = validFrames.count / fps 秒
```

> **為何要重新讀？** Pipeline 處理完每幀後立即釋放 pixel buffer，`RunnerPose` 只保留座標。重讀磁碟換取記憶體效率（1-2 幀 vs 整片 ~3GB）。

### Prescan bbox 影片

```
獨立跑一次 YOLO prescan → [FrameRange] + overlays{}
重新讀原始影片：
  frameIndex ∈ 有效範圍 → 疊 YOLO bbox → 寫入
  frameIndex ∉ 有效範圍 → 丟棄

輸出：只含 prescan 有效幀
```

---

## 已知問題與限制

| 問題 | 原因 | 建議方向 |
|---|---|---|
| 部分幀無 bbox（cadence=1 下） | YOLO 信心度 < 0.25 或 bbox 高度 < 40px | 調低 `detectorConf` / `minBoxHeight`；換更大模型（yolo26s/m） |
| overlay bbox 有時包不住完整跑者 | YOLO 生出力未加邊距；HRNet crop 有 25% padding 但 bbox 繪製無 | 繪製時將 bbox 擴大 25% |
| cadence > 1 時 YOLO 漏偵測後產生 gap | Tracker reset 後外插資料清空，需等下一個偵測幀 | 已改 cadence=1 消除；或改用 Kalman filter |
| `boxToCenterScale` aspectRatio 使用源幀比例 | 上游 Python pipeline quirk，原樣移植 | 需 parity 測試確認影響後再修 |
