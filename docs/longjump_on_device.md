# 跳遠分析移植到手機（LongJumpKit）

> 2026-11-19 建立。對應追趕計畫（cvat_upload/手機端與伺服器端差異與追趕計畫_2026-11-19.md）的階段 2（跳遠核心）與階段 3（沙痕）。

## 用途

伺服器的跳遠分析在 `runner-analysis-pipeline/core/longjump/`（Python）。它的輸入是骨架檔、影片第一幀和使用者點的沙坑校正，輸出踩板、離板、落沙、犯規、成績等結果。`Sources/LongJumpKit/` 是它的 Swift 版本，目標是**手機算出來的數字和伺服器一模一樣**。

LongJumpKit 只用 Foundation，不依賴 Core ML 或 AVFoundation，所以：

- 在 iPhone 上，它接在 RunnerPoseKit 產生的骨架後面；
- 在 Linux 上，它可以用 Docker 裡的 Swift 編譯和測試，不需要 Mac。

## 現況（2026-11-19）

| 項目 | 狀態 |
|---|---|
| 事件：片段修剪、騰空、落沙、踩板、離板 | 完成，33 案完全相同 |
| 起跳板偵測、起跳線、踩板位置判定 | 完成，33 案完全相同 |
| 起跳板被遮住時（只露出一小段）的判定 | 完成（session 9b749ffa） |
| 沙坑單應性、距離、助跑、失敗試跳 | 完成，完全相同 |
| 沙痕的搜尋邏輯（給定跑者輪廓） | 完成，5 個 session 完全相同 |
| 回顧圖形的資料（`_overlay`） | 完成，完全相同 |
| 整體分析 `LongJumpAnalysis.analyse` | 完成。33 案的整份結果都相同；唯一的差異是一條起跳線的繪圖座標差了 3e-12 px |
| 手機上的分割模型（Core ML） | 還沒做，見「沙痕」一節 |
| 接進 RunnerAnalysisKit／App | 還沒做，要在 Mac 上進行 |
| 檢查圖（landing_check.jpg 等） | 不移植。改成播放時再畫（計畫階段 4） |

## 怎麼用

```swift
import LongJumpKit

let result = LongJumpAnalysis.analyse(
    keypointsJSON: keypointsData,      // RunnerPoseKit 輸出的 pose/keypoints_2d.json
    cameraIndex: nil,                  // nil = 最後一台相機（拍沙坑的那台）
    firstFrame: PixelImage(width: w, height: h, layout: .bgra, bytesPerRow: rowBytes, data: bytes),
    pit: PitCalibration(imagePoints: anchors, worldPoints: metres),   // 沒有校正就傳 nil
    sandMarks: segmenter               // RunnerMaskSource；還沒有分割模型就傳 nil
)
let publicDocument = LongJumpAnalysis.publicResult(result)   // = long_jump_result.json
let text = JSONValue.object(publicDocument).serialized()
```

- 輸出的欄位、null 和數字型別都和伺服器的 `long_jump_result.json` 相同，前端可以直接讀。
- `sandMarks` 傳 nil 時，結果會加上警告 `segmentation_unavailable`，成績改用腳跟落點。伺服器在分割模型不可用時也是這樣處理。

## 模組

| 資料夾 | 內容 | 對應的 Python |
|---|---|---|
| `Model/` | PoseTrack、事件與起跳板等型別、門檻參數、有序 JSON | detection.py 的資料類別 |
| `Numerics/` | numpy／scipy 的運算（含 numpy 的 pairwise 加總）、Python 與 numpy 兩種四捨五入 | — |
| `Events/` | 片段修剪、騰空、落沙、踩板／離板、`detectJumpEvents` | detection.py |
| `Image/` | BGR→HSV、形態學、連通區域、距離轉換、Huber 直線擬合，和 OpenCV 4.13 逐位元一致 | OpenCV |
| `Board/` | 起跳板偵測、起跳線、踩板位置、被遮住的起跳板 | detection.py、takeoff_board.py |
| `Pit/` | 沙坑單應性（重現 `cv2.findHomography` 的 DLT 和 LM） | pit_homography.py |
| `Distance/` | 距離、助跑、失敗試跳、起跳判定、輸出 | distance.py、approach.py、failed_attempt.py、takeoff_board.py、result_output.py |
| `SandMark/` | 沙痕搜尋，以及 `RunnerMaskSource` 協定、ROI、跑者選擇 | sand_mark.py |
| `Analysis/` | `LongJumpAnalysis.analyse` | analysis.py |

## 怎麼驗證

每個 Swift 函式都會重播伺服器在真實案例上的每一次呼叫，用同樣的輸入比對同樣的輸出。

| 測試資料 | 怎麼產生 | 進 git 嗎 |
|---|---|---|
| `Tests/LongJumpKitTests/Fixtures/unit/` | `scripts/longjump/make_unit_fixtures.py`：numpy、scipy、OpenCV 在合成資料上的結果 | 是 |
| `testdata/longjump/` | `scripts/longjump/dump_longjump_fixtures.py`：伺服器跑 27 跳 GT 加 6 個後端 session，逐函式記錄（約 0.6 GB） | 否 |

```bash
# Linux（Docker 的 Swift 5.10，不需要 Mac）
scripts/longjump/swift_linux.sh test -c release -Xswiftc -enable-testing

# 伺服器的跳遠程式改了以後，重新記錄（需要 pipeline 環境和 TensorRT）
export LD_LIBRARY_PATH=$CONDA_PREFIX/lib:$TENSORRT_LIB_DIR
/home/jeter/.conda/envs/yolo_new/bin/python scripts/longjump/dump_longjump_fixtures.py
```

- **伺服器改了**：伺服器的跳遠規則一改，就重新記錄、重跑測試。不一致的地方就是手機要跟著改的地方。
- **Mac 上**：`swift test` 會一起跑這些測試。`testdata/longjump/` 要從 Linux 複製過去，或設定 `LONGJUMP_FIXTURES`，沒有的話相關測試會略過。

## 已知的細微差異

- **單應性**：5～6 個點的校正，矩陣只能和 OpenCV 一致到相對 1e-9 左右，因為 LM 收斂到一個很平的谷底。換算到世界座標差不到 1e-7 m，四捨五入後的成績完全相同。
- **數學函式庫**：直線擬合用到 `atan2`、`cos`、`sin`。iOS 的數學函式庫可能和 Linux glibc 差最後一位，要在 Mac 上跑一次測試確認。
- **影片解碼**：手機用 AVFoundation 解碼的第一幀，顏色換算可能和伺服器的 FFmpeg 略有不同（BT.601／709），起跳板的 HSV 門檻邊緣可能有少數像素不同。這要用實機拍的影片比對，Linux 上驗證不了。
- **錯誤訊息**：骨架檔讀不到時，警告寫成 `pose: <原因>`，不含檔案路徑。

## 沙痕：手機要用哪個分割模型（階段 3 量測）

`scripts/longjump/sand_mark_model_eval.py` 用伺服器自己的 `find_sand_mark`，換成手機可行的模型和輸入尺寸，在 30 個有落沙的案例上比較。結果存在 `~/runner-eval/longjump_port/sand_mark_eval.json`。

| 設定 | 5 個 session 的距離差 | GT 差超過 20 px | 身體部位相同 |
|---|---|---|---|
| x 1280 矩形（伺服器的同一個模型，PyTorch 版） | 0 | 0 | 23/23 |
| x 640 正方形 | 1.2–1.8 cm | 3 | 21/23 |
| s 640 正方形 | 1.8–3.0 cm | 5 | 16/23 |
| m 960 正方形 | 1.2–10.9 cm | 3 | 20/23 |
| n、l 和其他組合 | 部分 11–29 cm | 3–6 | 13–19/23 |

**結論：**

- 固定的正方形輸入或較小的模型，輪廓只要差一點，沙痕就可能從腳變成手或臀部，落點差到幾十公分。所以目前沒有一個手機設定能重現伺服器的沙痕。
- 伺服器本身在 25 跳有落地事件的 4K GT 裡，有 7 跳找不到沙痕，其中 4～5 跳小模型反而找得到。所以要用人工標註的真實沙痕來評估，而不是拿伺服器當答案。

**建議：** 手機先用腳跟落點給出估計成績（不傳 `sandMarks` 就是這樣），正式成績交給伺服器。之後補上沙痕的人工標註，再決定手機要用 x@640 還是 s@640。決定後，在 Mac 上實作一個 `RunnerMaskSource`：Core ML 的 YOLO26-seg 加上 `RunnerSegmentation.roi`／`chooseRunner`／`runnerMask`。

## 下一步（Mac 上）

1. 跑 `swift build` 和 `swift test`，確認 Xcode 的 Swift 編譯器和 iOS 的數學函式庫結果一致。
2. 把 `LongJumpKit` 接進 RunnerAnalysisKit：
   - 跳遠模式下，在骨架之後呼叫 `LongJumpAnalysis.analyse`；
   - 結果寫成 `longjump/long_jump_result.json`；
   - Flutter 外掛的 Podfile 要加上 `pod 'LongJumpKit', :path => ...`。
3. 第一幀：用 AVAssetReader 讀第一幀（BGRA），再包成 `PixelImage`。
4. 拿實機拍的跳遠影片，比較手機和伺服器的結果。可以用前端的 Compare 模式。
