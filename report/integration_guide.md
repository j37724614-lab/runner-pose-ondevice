# Runner Analysis Local / Server 整合計畫（v3）

> 更新日期：2026-10-08
> 本版取代 v2「手機只做 2D、server 繼續做下游分析」的 hybrid 方案。
>
> 新目標是：在 Flutter App 的**上傳頁面**讓使用者選擇「Server 運算」、
> 「Local 運算」或開發期使用的「Compare（兩者都跑）」。Server 模式沿用
> `runner-analysis-pipeline`；Local 模式則由
> iPhone 在裝置上完成與 server pipeline **功能等價**的分析。錄影頁面本期不接
> Local pipeline，仍維持既有 Server 流程。

## 1. 決策摘要

1. `runner-pose-ondevice` 不再只定位成 ANE 上的 HRNet 效能測試專案；它會逐步擴充成
   iOS 版完整分析引擎。現有 `RunnerPoseEngine` 保留為其中的 2D pose module。
2. Local 模式不是「本機算 keypoints、server 算其餘項目」。Local 必須完成 tracking、
   2D/3D pose、速度、leg identity、步態指標與必要輸出；backend 只負責帳號、RunSession、
   結果保存與跨裝置同步。
3. Flutter 在「分析執行者」這個 seam 上只依賴一個 interface，內部提供
   `ServerAnalysisAdapter` 與 `LocalAnalysisAdapter`。Compare 由 coordinator 同時協調兩個
   adapter，UI 不直接理解兩套 pipeline 的內部階段。
4. 運算模式使用 `AnalysisMode.server / AnalysisMode.local / AnalysisMode.compare`。畫面建議用
   Radio 或 Segmented Control 三選一；`compare` 的語意就是 Server 與 Local 都執行。不要使用
   兩個獨立 checkbox，避免兩個都沒選、結果覆寫與狀態組合不明確。
5. Local V1 只支援上傳頁中「同一台裝置一次取得完整相機影片集合」的流程。分次上傳、
   不同裝置補傳與錄影協作流程仍使用 Server，因為完整多相機 Local pipeline 必須同時取得
   所有影片、相機順序與校正資料。
6. Server pipeline 是 Local 實作的 reference oracle。功能一致代表輸入語意、輸出 schema、
   使用者可見指標與影片結果一致；不要求 Python 與 Swift 每個浮點數 bitwise identical。

## 2. 範圍

### 本期目標

- 上傳頁可選 `Server`、`Local` 或 `Compare`，預設為 Server。
- `Compare` 供開發期使用，對同一份輸入同時產生 Server 與 Local 結果及差異報告。
- Server 運算不改變既有成功路徑。
- Local 運算支援從檔案選擇器取得的影片，不依賴相機錄影流程。
- Local 最終支援 `runner-analysis-pipeline` 正式流程目前提供的主要能力：
  - 多相機 prescan、主跑者選擇、tracking 與 frame mapping。
  - HRNet WholeBody-23 2D pose。
  - COCO→H36M、腳部六點拆分、信心度處理、平滑、骨長與解剖限制修正。
  - MotionAGFormer 3D lifting 與角度。
  - bbox 速度／距離、可用時的 homography 世界座標速度。
  - leg identity、step/stride、heel/toe/contact 等正式流程輸出。
  - summary、metrics、angles、steps，以及產品需要的 overlay 影片。
- Local 結果可寫回現有 backend，並出現在既有歷史與結果頁。
- Server 與 Local 都產生同版本的 `AnalysisResultManifest`。

### 明確不在本期

- `record_camera_view.dart` 的 Local 分析。
- 多台手機錄影後在各手機分散運算，再合併結果。
- 完全離線的帳號、歷史紀錄與跨裝置同步。
- Android Local pipeline。
- 在第一階段移除或取代 Server pipeline。
- 要求兩種實作耗時相同或輸出逐 bit 相同。

## 3. 現況與目標差距

| 能力 | Server (`runner-analysis-pipeline`) | Local 現況 | Local 目標 |
|---|---|---|---|
| Prescan | 有 | 有 | 對齊正式參數與有效幀語意 |
| 主跑者 tracking | 多相機、frame/bbox map、crop offsets | 單影片 bbox tracker | 支援正式多相機 mapping 與校正資料 |
| 2D pose | HRNet WholeBody-23 | Core ML HRNet WholeBody-23 | 通過共同 golden fixtures |
| 2D 後處理 | Python/NumPy/SciPy | 僅 DarkPose decode | 移植正式 smoothing/normalization/status 邏輯 |
| 3D pose | MotionAGFormer | Core ML large/243 真機垂直切片已通過 | 完成 Server golden 數值 gate 與裝置矩陣 |
| 速度／距離 | bbox map + homography/pixel fallback | 已接正式 metrics artifact，待 Mac／真機 gate | Swift 與 Server golden 數值對齊 |
| Leg identity / gait | 有 | 無 | 移植 DP、step/stride、contact 邏輯 |
| Overlay | 多種結果影片 | 只有 2D skeleton benchmark overlay | 產生產品真正消費的必要影片 |
| 結果保存 | backend RunSession / DB / 檔案 | 無 | 上傳 result bundle 與原始影片供回放；backend 不以該影片重新運算 |
| Flutter 整合 | 既有 REST upload | plugin 骨架 | typed bridge + progress/cancel/error/result |

現有 S0–S5 雖然已有實作，但仍有 crop warp、DarkPose、真實 fixture、裝置記憶體與效能等
正式化 gate 未完成。因此狀態應定義為「2D module 已實作，尚未 production validated」，不能
把它直接視為完整 Local pipeline 的完成基礎。

## 4. 目標架構

```text
Upload UI
   │ AnalysisRequest + AnalysisMode
   ▼
AnalysisExecutor interface
   ├── ServerAnalysisAdapter
   │     └── 上傳原始影片 → backend → runner-analysis-pipeline
   │
   └── LocalAnalysisAdapter
         └── Flutter typed bridge
               └── RunnerAnalysisEngine (iOS)
                     ├── Input / calibration validation
                     ├── Tracking + frame mapping
                     ├── WholeBody-23 2D
                     ├── shared-contract postprocess
                     ├── 3D + angles
                     ├── speed + leg identity + gait
                     └── result bundle + overlay artifacts
                              │
                              └── backend 僅保存／同步，不重新分析

CompareAnalysisCoordinator
   ├── 固定同一份 AnalysisRequest / input hashes / config snapshot
   ├── 呼叫 ServerAnalysisAdapter
   ├── 呼叫 LocalAnalysisAdapter
   └── 等待兩筆結果 → ComparisonReport
```

這個 seam 已有兩個真實 adapter，因此不是為未來假設建立的抽象。它讓上傳 UI、進度畫面、
取消、錯誤處理與結果導頁只實作一次；Server/Local 的複雜度留在各自 adapter 內。

### Flutter interface（概念）

```dart
enum AnalysisMode { server, local, compare }

abstract interface class AnalysisExecutor {
  Stream<AnalysisEvent> analyze(AnalysisRequest request);
  Future<void> cancel();
}
```

上傳 UI 實際呼叫一個 coordinator，coordinator 依 `AnalysisMode` 選擇一個 adapter，或在
`compare` 模式協調兩個 adapter。Server/Local adapter 仍各自遵守相同 `AnalysisExecutor`
interface，因此比較邏輯不會散落在 controller 與 widget。

`AnalysisRequest` 至少包含：

- `schemaVersion`
- runner/session metadata
- `cameraCount` 與按 `cameraIndex` 排序的影片
- 每支影片的 fps、方向與實際 frame size
- anchors / homography calibration
- `isLongJump` 等運動模式
- output policy（是否產生大型 overlay）

`AnalysisEvent` 統一表示 validating、prescan、tracking、pose2d、pose3d、gait、export、sync、
completed 與 failed。Flutter 不應以 frame index 猜測總進度。

### iOS module

新增高階 `RunnerAnalysisEngine`，只公開一個主要分析 interface；現有 `RunnerPoseEngine`、
tracker、Core ML runners、數值處理與 exporter 都是它的內部 implementation。不要把每個 Python
stage 都變成 Flutter 可呼叫的方法，否則會得到一個淺而且難以演進的 interface。

建議 Swift Package 最終結構：

```text
RunnerAnalysisKit               # 對 Flutter 的高階 product
  Contracts/
  RunnerAnalysisEngine.swift
  Pipeline/
  Export/

RunnerPoseKit                   # 現有 2D module，可保留獨立 benchmark
  RunnerPoseEngine.swift
  Pipeline/S0...S5
```

repo 暫時不用改名；先讓 interface 與產物穩定，再決定 Flutter plugin 是否從 `runner_pose`
改名成 `runner_analysis`。

## 5. 共用結果契約

Server 與 Local 必須輸出同一份有版本的 `AnalysisResultManifest`。不要把 Python 內部檔案路徑
直接當成跨平台 interface。

建議 result bundle：

```text
analysis-result/
  manifest.json
  summary.json
  metrics.json                 # CSV 可另附，但 App 使用 JSON schema
  angles.json
  steps.json
  pose/
    keypoints_2d.npz|bin
    foot_keypoints.npz|bin
    keypoints_3d.npz|bin
  artifacts/
    main_overlay.mp4           # 依 output policy 選配
    cam<N>_overlay.mp4          # 選配
  diagnostics/
    timing.json
    warnings.json
```

`manifest.json` 必須記錄：

- `schema_version`、`engine_version`、`compute_location`
- `analysis_run_id`、可選的 `comparison_group_id`
- model identity/hash、compute units、裝置與 OS
- camera/frame coordinate conventions
- 已完成與被略過的 stage
- 每個 artifact 的類型、相對路徑、hash 與 byte size
- warnings、fallback 與 degraded-result 原因

### 座標與 frame mapping 契約

這部分必須在開始移植演算法前鎖定：

- 23 點輸入是原始影片像素座標，順序維持既有 `JointName`。
- bbox 使用 `[x1, y1, x2, y2]`，原點左上，單位為原始影片像素。
- 每個 pose frame 明確帶 `camera_index`、`source_frame`、`timestamp`、`valid`、
  `bbox_extrapolated`，不能只依 array index 推測。
- Server 的 `offsets.npz` 實際包含 crop 左上角 `offsets`、`orig_frames`、`cam_indices`。
  Local 可在內部使用 typed frame map，不必把 NPZ 當核心資料模型；只有 parity/export adapter
  需要產生相容 NPZ。
- Local joints 若全程保持原始影片座標，legacy adapter 可輸出 zero offsets，但 3D normalization、
  overlay 尺寸與 bbox 必須使用同一 coordinate space，不能只把 offsets 歸零而忽略影像尺寸。

## 6. 上傳頁 UX

### 選擇位置

在上傳功能的共同入口加入三種模式：

```text
運算方式
  ● Server 運算（預設）
    上傳影片，由伺服器分析；支援既有所有上傳方式。

  ○ Local 運算
    在此 iPhone 分析，再同步結果；耗用電量、儲存空間且需支援的裝置。

  ○ Compare（開發模式）
    同一份影片同時跑 Server 與 Local，保留兩份結果並產生效能／正確度差異報告。
```

選項必須在挑選影片與建立 temp upload 前確定。開始處理後鎖定，若要切換必須取消目前工作並
重新確認，避免同一 RunSession 混用兩種來源。

### Server 路徑

- 保留目前 `uploadVideo`、`uploadAllInfo`、backend `run_analysis()` 行為。
- Local feature flag 關閉時，畫面與現在完全相同。

### Local 路徑

1. FilePicker 優先使用檔案 path/URL，不先把完整影片讀成 Dart `Uint8List`。
2. 將安全範圍外或生命週期不穩定的檔案複製到 App sandbox staging directory。
3. 收齊全部 camera inputs、anchors 與 session metadata 後才開始分析。
4. 顯示 stage、百分比、預估空間、thermal warning 與取消按鈕。
5. 完成後先在本機驗證 result manifest/hash，再上傳 result bundle。
6. backend 建立／更新 RunSession，之後沿用既有結果與歷史頁。

### Compare 路徑

1. 對影片、camera order、anchors、fps 與分析設定建立 immutable snapshot 及 input hashes。
2. 先完成原始影片上傳；上傳完成後啟動 Local，Server 也可開始遠端運算。這可避免大型上傳
   與 Local 影片解碼同時爭用裝置 I/O，又能讓兩端運算大致並行。
3. Server 與 Local 各自建立獨立 `analysis_run_id`，共用同一個 `comparison_group_id`。
4. 任一路徑完成時先保存結果；另一條失敗不能覆蓋或刪除已成功結果，整體標記為 partial。
5. 兩者都完成後產生 `ComparisonReport`。Server 是目前的 reference baseline，但差異不等同
   Local 一定錯誤；超過 P0 核准門檻才標記 regression。
6. Local 與 Compare 都必須在開始前明示「原始影片與分析結果會同步至 Server，供歷史與回放使用」；
   差異是 Local 的分析運算仍完全在裝置完成，backend 不會拿該影片重跑 Server pipeline。

效能報告至少分開記錄：

- Server queue、upload、server compute、download/sync 與 server end-to-end。
- Local staging、local compute、result sync 與 local end-to-end。
- Local peak memory、thermal transitions、compute units、電量變化與裝置型號。
- 各 stage 的 elapsed time；不能只比較一個總秒數。

正確度／結果差異報告至少包含：

- bbox match rate、IoU 與 frame mapping 差異。
- 2D body/foot joint mean、median、p95 pixel delta、PCK 與 confidence delta。
- 3D joint、angle time-series 差異。
- speed/distance/step/stride summary delta。
- touchdown/contact event 的 matched、missing、extra 與 frame offset。
- stage warnings、fallback 與產物缺失。

### V1 可用性限制

- Local 只在 iOS、支援裝置、模型已就緒、儲存空間足夠時可選。
- Local V1 只開放「一次選齊所有影片」；`upload_seperately_view.dart` 中既有跨時間／跨裝置
  補傳仍固定使用 Server。
- Compare 與 Local 有相同輸入限制，因此 V1 也只開放於 Upload All。
- 錄影頁完全不顯示 Local 選項，`record_camera_view.dart` 不接 `LocalAnalysisAdapter`。
- Local 失敗時顯示「重試 Local」或「切換 Server 重新分析」。正常 Local 完成同步會上傳
  原始影片與結果 bundle；切換 Server 屬於另一次運算，仍須再次確認，不能靜默啟動。

## 7. Backend 角色調整

新增 Local result ingestion，而不是 `/analyze/keypoints`：

- 建立 Local RunSession 並回傳 upload/session id。
- 接收、驗證有版本的 manifest 與 artifacts。
- 驗證 hash、camera 數量、schema version、必要輸出與 runner ownership。
- 將 summary/metrics/angles/steps 寫入目前結果頁使用的資料模型。
- 保存可選 overlay；標記 `compute_location=local`、engine/model version。
- ingestion 不呼叫 `runner-analysis-pipeline`，避免 Local 結果被 server 重算。
- ingestion 必須具備 idempotency；網路中斷重送不能建立重複 RunSession。
- 一個 RunSession 可關聯多個 `AnalysisRun`；Compare 的 Server/Local run 以
  `comparison_group_id` 成對保存，不能共用一組會互相覆寫的結果欄位。
- 保存 `ComparisonReport`，並允許依 run 單獨讀取結果或查看兩者差異。

大型 artifacts 應分開、可續傳。第一個 vertical slice 可以使用 multipart result bundle，正式版
需設定大小限制、分段或 object storage upload 策略。

## 8. 各 repo 變更

### `runner-pose-ondevice`

- 建立 `RunnerAnalysisEngine` 與 request/event/result contracts。
- 保留並正式化 `RunnerPoseEngine`，補完 accuracy、memory、thermal gates。
- 逐階段移植 server 的正式演算法，不以重寫的近似版本直接取代。
- 將 MotionAGFormer 轉為 Core ML，記錄模型 hash、輸入正規化與輸出 shape。
- 建立 result bundle writer 與 legacy NPZ/CSV parity adapter。
- 完成 typed Flutter bridge、取消、錯誤 mapping 與 background/foreground lifecycle。
- 輸出 stage timings、模型／裝置資訊與穩定的 input/result hashes，供 Compare 使用。
- 解決 CocoaPods/SwiftPM 包裝與 iOS deployment target；目前 host 12/13 與 package 16 不一致。

### `runner-analysis-pipeline`

- 定義並輸出 canonical manifest/JSON schema，作為 Server 與 Local 的共同契約。
- 把可獨立驗證的數值 stages 建立 golden fixtures，而不是讓 Swift 測試解析整個 Python repo。
- 每個 fixture 包含輸入、期望輸出、模型版本與容許誤差。
- 保持 Server 正式路徑可用，Local 開發期間它仍是 oracle 與 fallback。

### `running-analysis-backend`

- 新增 Local result session/ingestion endpoints。
- 將 local manifest 映射到既有 RunSession、graph、CSV/PDF/歷史查詢。
- 加入 schema/version/hash/idempotency 驗證。
- 清楚區分 `compute_location=server|local`，方便 A/B、診斷與回滾。
- 新增 `AnalysisRun`／comparison group 儲存模型與 ComparisonReport 查詢。

### `running-analysis-frontend`

- 新增 `AnalysisMode`、共同 `AnalysisExecutor` interface、兩個 adapter 與 compare coordinator。
- 上傳共同入口加入 Server/Local/Compare segmented control；正式環境可用 feature flag 隱藏 Compare。
- `UploadAllController` 不再在選檔瞬間必然呼叫 `uploadVideo`；由選定 adapter 決定 staging 或上傳。
- Local 使用 native path/URL，避免 `withData: true` 將多支影片同時載入 Dart heap。
- 加入 Local capability、模型狀態、磁碟、thermal、progress、cancel 與 result sync state。
- Compare 畫面同時呈現兩條獨立進度、成功／失敗狀態與差異摘要。
- `record_camera_view.dart` 保持既有 Server 行為，不注入 Local adapter。

## 9. 執行階段與驗收 gate

### P0 — 契約與基準資料

- 盤點 Server 正式 pipeline 的輸入、輸出與所有使用者可見欄位。
- 定義 `AnalysisRequest`、`AnalysisEvent`、`AnalysisResultManifest` 與 `ComparisonReport` v1。
- 建立至少包含單相機、多相機、遮擋、跨相機切換、長跳、無 homography 的 golden sessions。
- Server 匯出 canonical fixture bundle 與 stage-level fixtures。

**Gate：** schema review 完成；同一 fixture 可重現產生相同結構；所有座標與 frame index 語意有測試。

### P1 — Local engine 外殼與一條垂直切片

- 建立 `RunnerAnalysisEngine`、typed Flutter bridge、progress/cancel/error。
- 建立 Server/Local adapters 與開發用 feature flag。
- 建立 compare coordinator；同一 request snapshot 能產生兩個不互相覆寫的 analysis runs。
- 完成「單影片 → 現有 2D → result manifest → backend test ingestion → 結果頁」垂直切片。
- 這一階段只供內部測試，不宣稱功能 parity。

**Gate：** UI 不知道 native stage 細節；取消後無孤兒 Task/暫存檔；重送 ingestion 不重複建 session；
Compare 任一端失敗時另一端結果仍可讀取。

### P2 — Tracking、2D 與後處理 parity

- 補正式多相機 frame map、bbox map、crop/offset semantics。
- 鎖定 YOLO 主跑者選擇與 interpolation 行為。
- 完成 HRNet/DarkPose fixtures。
- 移植 COCO→H36M、foot split、confidence status、SG smoothing、bone/anatomical corrections。
- foot 六點保持 server 現況：在 body smoothing 前拆出，除非 Server 與 Local 同時變更契約。

**Gate：** 所有 stage fixture 在核准容許誤差內；無 frame drift、左右腳或 camera index 位移。

### P3 — 3D 與角度

- 將正式 MotionAGFormer checkpoint 轉成 Core ML。
- 驗證 sequence window、padding/resampling、normalization、flip augmentation 與輸出關節順序。
- 移植角度與 supplementary-angle correction。

**Gate：** golden sessions 的 3D joint/angle 誤差通過資料集基準；ANE fallback 與不支援裝置錯誤可預期。

### P4 — 速度、leg identity 與 gait

- 移植 bbox speed、pixel/homography modes、Kalman/Butterworth 與 confidence。
- 移植 leg identity DP、touchdown/heel/toe、step/stride 與 long-jump 分支。
- 對齊 summary metrics 與結果頁實際使用欄位。

**Gate：** 事件數、左右腳 identity、速度、步幅與關鍵 summary 在 golden sessions 通過核准門檻。

### P5 — Artifacts、同步與上傳 UI

- 完成必要 overlays、result bundle writer、artifact hash。
- 完成 Local result ingestion 與大型 artifact 重試／續傳策略。
- 在 Upload All 正式顯示 Server/Local/Compare 選項；Upload Separate 與 Record 保持 Server。
- 完成 ComparisonReport 產生、保存與開發用檢視頁。
- 加入 retry local / switch to server 的明確 UX。

**Gate：** Local 結果能在既有歷史、圖表、CSV/PDF 與回顧頁正確顯示；上傳頁在開始前清楚告知
原始影片會與結果一起同步，且 backend 不會將 Local 影片重新送入 Server pipeline。

### P6 — 裝置正式化與漸進發布

- 在目標 iPhone 矩陣量測時間、peak memory、磁碟、耗電與 thermal throttling。
- 模型下載／版本／cache／rollback 策略完成。
- 先以 internal flag 發布，再按裝置 allowlist、使用者比例逐步開啟。
- 追蹤 Server/Local 的成功率、耗時、結果差異、fallback 與 crash。

**Gate：** correctness gates 全過；長影片無隨幀數成長的記憶體；背景切換與低磁碟可恢復；Server fallback 保持可用。

## 10. 測試策略

測試 surface 是 `RunnerAnalysisEngine` 與共同 result contract，不把每個內部 class 都暴露給 Flutter。

1. **Stage parity tests**：Python 產 fixture，Swift 對相同輸入產輸出並比較。
2. **End-to-end golden tests**：同一組影片分別跑 Server/Local，比較 manifest 與產品指標。
3. **Compare tests**：驗證相同 input hashes、雙 run 保存、partial success 與差異指標。
4. **Schema tests**：backend、Flutter、Swift 對相同 manifest fixture decode/encode。
5. **Failure tests**：模型缺失、低磁碟、thermal、取消、App background、網路中斷、續傳。
6. **Performance tests**：各 stage latency、effective FPS、peak memory、energy、thermal transition。
7. **Regression corpus**：背景人物、遮擋、漏偵測、跨相機、左右腳交換、不同 fps/方向/解析度。

容許誤差不能先憑直覺填數字。P0 先在代表性資料集量測 Server 重跑變異、Core ML 轉換誤差與
裝置差異，再凍結 body/foot/3D/angle/speed/gait 各自的 acceptance threshold。

## 11. 主要風險與處理方式

| 風險 | 影響 | 處理 |
|---|---|---|
| MotionAGFormer 無法直接穩定轉 Core ML | 3D parity 阻塞 | P0/P1 優先做 conversion spike，不等 2D 全完成 |
| Python/SciPy 數值行為難以完全重現 | gait/速度漂移 | stage fixtures + 明確容許誤差；必要時用 Accelerate/vDSP |
| 多相機檔案與中間產物占用過大 | App 被 jetsam 或磁碟不足 | path-based I/O、bounded pipeline、分 stage 落盤與清理 |
| ANE/GPU thermal throttling | 長影片時間不可預期 | progress/thermal event、降級策略、裝置 allowlist |
| 模型總大小過大 | App bundle 膨脹 | 版本化下載、hash 驗證、cache 與 rollback，不全部綁進主 bundle |
| Local 與 Server schema 漂移 | 結果頁或 backend ingestion 失敗 | 單一 versioned manifest + 跨 repo contract fixtures |
| Compare 同時工作污染效能數據 | Local I/O、thermal 或總時間失真 | 上傳完成後才啟動 Local；分開記錄 compute 與 end-to-end |
| Compare 結果互相覆寫 | 無法追查差異 | 一個 RunSession 下保存兩個 AnalysisRun 與 comparison group |
| 使用者誤以為 Local 等於完全離線 | UX 誤解 | 文案明示「本機運算，結果仍需同步」；另立 offline 專案範圍 |
| 使用者誤以為 Local 不會同步原始影片 | 隱私期待與實際行為不一致 | 開始前明示影片與結果都會同步；fallback Server 必須再次確認 |

## 12. 動工前必須確認

1. Local V1 的最低 iPhone 型號、iOS 版本、可接受分析時間與記憶體上限。**暫緩**——等
   Step 0 的 iPhone 17 Release baseline 數據回來後再定具體門檻，不用 Debug 數據猜測。
2. Local 結果是否必須包含所有 overlay/PDF，或 V1 可先同步數值與必要回顧影片。**已確認**：
   依照本文件既有「本期目標」所列範圍即可（summary/metrics/angles/steps + 產品需要的
   overlay），不再額外收斂或放寬。
3. Local 是否只支援 Upload All；本計畫建議是。**已確認採納**：Upload Separate 與錄影頁
   這次維持 Server-only，不新增本機 session staging。
4. 模型採 App 內建或首次使用下載；本計畫建議大型 HRNet/MotionAGFormer 採版本化下載。
   **已確認採納**：HRNet/YOLO/MotionAGFormer 一律版本化下載，首次使用時抓取，App 本體
   維持小體積。
5. backend 保存 Local 結果後是否同步原始影片。**已於 2026-10-08 變更決策**：Local 分析完成後，
   原始影片會與 result bundle 一起上傳，供既有 RunSession 回放與後續稽核；backend 只保存／同步，
   不重新執行 Server pipeline。上傳頁必須在開始前明示此行為。
6. parity 的產品定義：哪些 summary、圖表、CSV、PDF、影片是正式必需輸出。見第 2 項。
7. Compare 是只供 debug/internal build，或未來也開放給一般使用者；本計畫建議初期由 feature flag 控制。**已確認採納**。

在以上事項確認前，可以先做 P0 契約、golden corpus 與 MotionAGFormer Core ML conversion spike；
這三項不依賴最終 UI 決定，也是整個計畫風險最高、最早應驗證的工作。

## 13. 逐步修改與執行清單

本節是實際施工順序。原則是一次只推進一個 step；當前 step 的完成條件未通過，就不開始
依賴它的下一步。每完成一項，將 `[ ]` 改成 `[x]`，並在該項下補上 commit、測試結果、裝置與
已知差異。

### 執行規則

- 每個 step 優先維持成一個可 review、可回滾的 commit 或 PR。
- 不在同一個 step 同時移植多個演算法 stage。
- Server 現有正式結果不得因 Local 開發而改變；必要重構先用 characterization tests 鎖定。
- 所有跨 repo schema 變更先修改 canonical contract，再更新各語言 adapter。
- Compare 永遠保存兩個 `AnalysisRun`，禁止用 Local 結果覆蓋 Server 結果。
- 效能數據必須記錄 Release build、裝置、OS、thermal、模型 hash 與輸入 hash。
- Swift/Core ML 的實機驗收在 Mac + iPhone 執行；Linux 只執行 Python、schema 與可用的 Flutter/backend 測試。

### Step 0 — 凍結四個 repo 的起始基準

- [x] **修改 repo：** 四個 repo；只新增基準紀錄，不改正式行為。
- [x] 記錄各 repo 的 branch、HEAD、dirty files、工具版本與模型版本。
- [ ] 執行現有可用測試並保存結果：
  - `runner-analysis-pipeline`：正式測試／characterization tests。
  - `running-analysis-backend`：backend tests。
  - `running-analysis-frontend`：`flutter analyze`、`flutter test`。
  - `runner-pose-ondevice`：Mac 上 `swift build`、`swift test` 與一輪 BenchApp baseline。
- [x] 在 `runner-pose-ondevice/report/` 建立執行紀錄，保存已完成基準與已知失敗；裝置 FPS、peak memory、thermal 待 Mac/iPhone 補測。

目前狀態：Linux baseline、Mac generic iOS Release build 與三個 Core ML 來源模型 hash 已完成；
Mac `swift test` 已確認受 iOS-only `UltralyticsYOLO/UIKit` dependency 阻擋；iPhone 實機
已有三次 Debug／YOLO26L 暫定數據。BenchReport 已補上 hardware identifier 與執行前後電量，
等待 Mac build 與正式 Release baseline 驗證。詳見
`report/local_pipeline_execution_log.md`。

**2026-10-14 detector 補測決策：** 正式預設維持 `yolo26l`；因實際影片有偵測效果不佳的情況，
BenchApp 新增官方 INT8 `yolo26x` 選項，後續以同一影片比較 bbox miss、bbox IoU、detect latency、
effective FPS、peak memory 與 thermal，再決定是否調整正式模型或 detection cadence。

**完成條件：** 四個起始 commit 可追溯；已知失敗與新回歸可以區分；後續比較有固定 baseline。

### Step 1 — 確認 V1 產品決策

- [x] **修改 repo：** 只更新本規劃書與執行紀錄。
- [ ] 確認最低 iPhone/iOS、可接受時間、記憶體與磁碟上限——**暫緩**，待 Step 0 的 iPhone
      17 Release baseline 數據回來後再定。
- [x] 確認 Local/Compare V1 只支援 Upload All。
- [x] 確認 V1 必須輸出的 summary、圖表、CSV、PDF、overlay——維持本文件既有「本期目標」範圍。
- [x] 確認 Compare 只在 internal/debug feature flag 顯示。
- [x] 確認模型採版本化下載；Local 原始影片與 result bundle 一起同步供 RunSession 回放，
      backend 不重新分析，UI 必須事前明示。

**完成條件：** 第 12 節所有問題都有書面決策；沒有影響 schema 的未決產品問題。**除「最低裝置
門檻」依賴 Step 0 Release baseline 數據外，其餘已於 2026-10-04 定案**；已定案的部分不影響
Step 2 canonical contract 的 schema 結構，不阻塞後續 step。

### Step 2 — 建立 canonical contract v1

- [x] **主要 repo：** `runner-analysis-pipeline`。
- [x] 新增 `contracts/analysis/v1/`，作為唯一 source of truth。
- [x] 定義並提供 fixture：
  - `AnalysisRequest`
  - `AnalysisEvent`
  - `AnalysisResultManifest`
  - `ComparisonReport`
  - summary、metrics、angles、steps 與 artifact descriptors
- [x] 明定 joint order、bbox、camera index、timestamp、座標系統、單位、nullability 與版本相容規則；frame index 保留在逐幀 artifact schema 階段細化。
- [x] 加入 JSON Schema 正反 fixture 驗證與 JSON round-trip tests；`runner-analysis-pipeline` 完整測試通過。

**完成條件：大致達成，但有一個中度缺陷（2026-10-04 審查）。** 四種文件皆有合法／非法
fixture，且 `jsonschema` 驗證是真的在跑（`tests/contracts/test_analysis_contract_v1.py`），
不是裝飾用的檢查。**但**：schema 宣告的 `joint_order` 是 23 點原始 COCO-WholeBody 順序，
golden corpus 裡實際的 `pose2d` fixture（`pose2d_raw.json`／`pose2d_post.json`）卻是「腳部
六點拆分 + COCO→H36M 重排」之後的 17-joint 資料——兩者對不上，且 `artifact.type` 沒有區分
body pose2d 與 foot keypoints。這正是本文件 §5 一開始就點名的風險，目前**沒有正確處理**。
建這些 fixture 前，必須先新增一份真正的「原始 HRNet 23-joint 輸出」fixture（在 foot-split
與 COCO→H36M 重排**之前**），schema 也要能分別描述這兩個階段，否則 Step 16 會同時卡在
HRNet 推論、foot-split、COCO→H36M 重排三個問題上，無法逐一排查。

### Step 3 — 讓 Server 輸出共同 manifest

- [x] **主要 repo：** `runner-analysis-pipeline`。
- [x] 在 `run_analysis()` 外加 manifest adapter，不改動既有演算法結果。**2026-10-04 補上
      接線**：新增 `run_analysis_with_manifest()`（`core/pipeline/final_export.py`，
      `run_analysis()` 之後），對同一組 `analysis_config`/`options` 用
      `_normalize_analysis_config` + `_resolve_analysis_output_directory`（與
      `run_analysis()` 內部用的是同一份純函式，保證輸出目錄一致）算出 output dir，呼叫
      `run_analysis()` 拿到結果後直接轉給 `write_server_manifest()`。**不修改
      `run_analysis()` 本身**，呼叫端（目前已接：`analyze.py` 的 demo `__main__`）改用
      這個新函式即可同時拿到既有回傳值與 `manifest.json`。已加 `tests/contracts/test_run_analysis_with_manifest.py`
      兩個測試（monkeypatch 掉 `run_analysis` 避免真的跑 GPU/影片），驗證：(1) wrapper
      把參數原封不動轉給 `run_analysis()`、回傳值完全不變；(2) `manifest.json` 確實寫進
      跟 `run_analysis()` 一致的輸出目錄。
- [x] 將既有 metrics、angles、steps、模型資訊、stage timings 與 artifacts 映射到 contract v1。
- [x] 計算 input hashes、config hash、model/artifact hashes，並輸出 manifest SHA-256 sidecar；hashing 邏輯正確且 deterministic（已驗證重跑兩次 byte-identical）。
- [x] 為同一輸入重跑建立 deterministic-structure test（已驗證通過）。

**完成條件：已達成（2026-10-04 補線後）。** `yolo_new` 環境 `pytest -q tests` 目前
**194 passed**（192 既有 + 2 個新測試）。**注意**：`run_analysis_with_manifest()` 目前只
接進這個 repo 自己的 `analyze.py` demo；正式 production 實際呼叫路徑是
`running-analysis-backend/routes/upload.py::analyze_and_save()`，那邊改呼叫新函式是
backend 側的工作（屬於 Step 9/10 範圍），這裡先不動 backend repo。

> **模型替換問題已由使用者確認非阻塞（2026-10-04）**：`MotionAGFormer/demo/vis.py` /
> `preprocess.py` 裡把 3D checkpoint 從 large 換成 small、刪減後處理邏輯的未 commit
> 改動，使用者確認「沒有動到主流程，只是自己在做測試」，不視為本計畫的阻塞項，**不需要
> 拆 commit 或重錄 golden corpus**。下方 Step 4 的「基準不可信」警語因此降級為記錄用途，
> 不再要求動工前處理。

### Step 4 — 建立 golden corpus 與 stage fixtures

- [x] **主要 repo：** `runner-analysis-pipeline`。
- [x] 準備單相機、多相機、遮擋、跨相機、無 homography、左右腳易交換、長跳等 session（遮擋與長跳 fixture 為合成資料，`edge_cases/metadata.json` 已誠實標記 `"synthetic": true`，不是真實 Server 錄製）。
- [x] 逐 stage 輸出最小 fixture：tracking、2D raw、2D postprocess、3D、speed、leg identity、gait（但見上方 Step 2 完成條件：`2D raw` 實際上已經是 foot-split + COCO→H36M 重排之後的資料，不是真正的 HRNet 原始輸出）。
- [x] fixture 記錄 pipeline commit、source hash 與產生指令。
- [x] 以同一短片完整重跑 Server 兩次，量測 tracking、2D、3D、angles、steps 自然變異並制定 provisional tolerance。

**完成條件：已達成，一項已知記錄用途的落差（2026-10-04 更正）。** Fixtures 格式正確、
source hash 與 tolerance tests 都有驗證通過。`golden/server_repeatability.json` 記錄的是
`motionagformer_s_ap3d`（使用者確認這是自己平行測試用的模型替換，非本計畫改動，見上方
Step 3 附註，不視為阻塞）。唯一仍待修正的是 `2D raw` fixture 其實不是真正的原始 HRNet
輸出，而是 foot-split + COCO→H36M 重排之後的資料（見 Step 2 完成條件）——這個會在
Step 16（2D 正式後處理 parity）之前另外補一份真正的原始輸出 fixture 處理，不影響現在
繼續往下推進。

### Step 5 — MotionAGFormer Core ML 可行性 spike

- [x] **主要 repo：** `runner-pose-ondevice`；reference 來自 `runner-analysis-pipeline`。
- [x] 使用正式 checkpoint 轉 Core ML，不先建立完整產品包裝（`scripts/motionagformer_coreml_spike.py`，
      官方 `MotionAGFormer-large.yaml` + `motionagformer-l-h36m.pth.tr`）。
- [x] 驗證 81/243 sequence window、dynamic/static shape——**結論：`n_frames` 是建構模型時
      就烘進 graph 的靜態參數（temporal GCN 層用 `num_nodes=n_frames`），不是 runtime
      可變 shape；243（官方 large）與 81（small/ap3d）需要各自匯出固定 shape 的
      `.mlpackage`，不能共用一個動態模型**。normalization/resampling/flip augmentation
      發生在模型輸入前後的 host 端程式碼（`normalize_screen_coordinates`/`flip_data`），
      不在模型 graph 內，不影響轉換；joint order 不變（17-joint H36M，與 contract v1 現有
      schema 一致）。
- [ ] 在目標 iPhone 測 CPU/GPU/ANE 可用性、latency、peak memory 與輸出誤差——**待 Mac/iPhone**，
      Linux 上 Core ML 無法執行推論（`Model prediction is only supported on macOS`），
      已把 PyTorch 參考輸出/輸入存好（`report/motionagformer_coreml/*/reference_output.npy`、
      `example_input.npy`）供之後在 Mac 上比對數值誤差。
- [x] 記錄不支援的 Core ML op、fallback 與轉換腳本——發現並**驗證修正**了一個會讓轉換
      直接失敗的 rank-6 reshape（`attention.py`/`ctr_attention.py` 的 QKV 合併 reshape），
      修正前後用同一組輸入跑完整模型比對，誤差 `0.0`（bit-identical）。另記錄一個
      coremltools 9.0 + NumPy 2.x 的相容性 bug（`int()` cast 一個 shape (1,) 陣列），
      已用 monkeypatch 繞過，沒有動共用 `yolo_new` 環境的 NumPy 版本。詳見
      `report/motionagformer_coreml_spike.md`。

**完成條件：已達成，結論 GO（2026-10-04）。** large/243（官方）與 small/81（使用者測試用）
兩種組合套用上述 reshape 修正後都成功轉換成 `.mlpackage`（38 MB / 11 MB，fp16）。**唯一
剩下的驗證項目**是數值正確性，必須等 Mac/iPhone 才能跑 Core ML 推論比對——這不影響
「go/no-go」結論，因為轉換可行性與模型結構限制已經確認清楚，不是模糊地帶。下一步建議：
決定 attention reshape 修正要不要落地成 `runner-analysis-pipeline` 的正式程式碼（對現有
Python 推論路徑無副作用，純 reshape 分解），而不是永遠留在 export-only 腳本裡
monkeypatch；這個決定本身不阻塞 Step 6（`RunnerAnalysisKit` 外殼）的開工。

### Step 6 — 新增 `RunnerAnalysisKit` 外殼

- [x] **主要 repo：** `runner-pose-ondevice`。
- [x] 在 `Package.swift` 新增 `RunnerAnalysisKit` product/target，保留現有 `RunnerPoseKit`。
- [x] 建立 Swift contract types、`RunnerAnalysisEngine`、`AnalysisEvent` stream、取消與 typed errors。
- [x] 透過 dependency injection 接收 2D module、儲存與 clock；測試使用 in-memory adapter。
- [x] 此 step 暫時只回傳 degraded 診斷 manifest，不移植新演算法。

**完成條件：已達成（2026-10-04）。** 新增
`Tests/RunnerAnalysisKitTests/RunnerAnalysisEngineTests.swift`，覆蓋完成、驗證失敗、處理失敗與取消的
固定事件順序；新 target 不修改既有 `RunnerPoseKit`/BenchApp。Mac 執行
`swift test --filter RunnerAnalysisEngineTests`：**4 tests passed、0 failures**。為讓 SwiftPM 的
macOS test graph 不再誤編譯 iOS-only Ultralytics target，另將該 product dependency 限制為 iOS，
並在非 iOS build 排除 YOLO adapter；iPhone 上的 YOLO 行為不變。

### Step 7 — 將現有 `RunnerPoseEngine` 接入高階 engine

- [x] **主要 repo：** `runner-pose-ondevice`。
- [x] 把現有 S0–S5 當成 `RunnerAnalysisEngine` 內部的 2D implementation。
- [x] 將 `RunnerPose` 轉成 contract frame：camera/source frame、timestamp、bbox、23 joints、valid、extrapolated。
- [x] 建立本機 staging/output directory lifecycle 與清理規則。
- [x] 產生最小 `AnalysisResultManifest`、2D result 與 timing diagnostics。

**完成條件：已達成（2026-10-04）。** 已新增 `RunnerPose2DAdapter`、原始影片座標的
`Pose2DFrame` contract，以及使用 staging directory 後才發布完成目錄的
`LocalAnalysisResultStore`；Mac 的 7 個 `RunnerAnalysisKitTests` 全數通過，generic iOS Release
build 成功。iPhone 17 使用 `IMG_0085.MOV`／`yolo26n` 完成高階 interface：2D wall time
12.588 秒，輸出 315 frames（133 valid、182 invalid），所有 valid frame 皆有 23 joints、
source frame 嚴格遞增；manifest 通過 canonical v1 schema，pose2d 與 diagnostics 的實際
byte size／SHA-256 均與 manifest 完全一致。原本直接呼叫 `RunnerPoseEngine` 的 BenchApp Run
流程亦已在同一裝置成功執行。

### Step 8 — 建立 Local result bundle writer

- [x] **主要 repo：** `runner-pose-ondevice`。
- [x] 實作 manifest、內嵌 summary、目前 2D 階段的 diagnostics、artifact descriptors 與
      SHA-256；真正的逐幀 metrics 要等後續 speed/gait stage 產生資料後才加入，writer 不製造
      假資料或空 artifact。
- [x] 支援 atomic finalize：分析失敗時不能留下看似成功的 bundle，並另外輸出
      `manifest.sha256` sidecar。
- [x] 支援取消清理、低磁碟預檢與 staging recovery。
- [x] 增加 manifest、pose2d contract round-trip、digest、低磁碟、取消與 recovery tests。

**完成條件：已達成（2026-10-08）。** `LocalAnalysisResultStore` 先將所有
內容寫入隱藏的 `.<run-id>.staging`，完成後才以同檔案系統 move 發布；任何寫入錯誤或取消都
清掉 staging。啟動新輸出前會清理超過 24 小時的 abandoned staging，並預留 64 MiB 可用
空間；不足時由高階 engine 保留為 `insufficient_storage` typed failure。測試亦會重新 decode
已輸出的 manifest／pose2d 並驗證 manifest digest。Mac/iPhone 實機 Local 流程已由使用者驗收，
result bundle 能完成產生、同步與結果頁消費，符合目前內部測試標準。

### Step 9 — Backend 建立 `AnalysisRun` 資料模型

- [x] **主要 repo：** `running-analysis-backend`。
- [x] 新增 `AnalysisRun`、`compute_location`、`comparison_group_id`、engine/model/schema version、status 與 timings
      （`db_models/analysis_run.py`，新表，`id`/`run_session_id`/`compute_location`/
      `comparison_group_id`/`schema_version`/`engine_version`/`status`/`timings`(JSON)/
      `created_at`/`completed_at`）。
- [x] 將 `RunSession → AnalysisRun[]` 建成一對多，不破壞既有 Server session 查詢
      （`RunSession` 新增 `analysis_runs: List["AnalysisRun"]` relationship，**完全不動**
      既有 `analysis: Optional["AnalysisMeta"]` 的欄位/查詢）。
- [x] 建立 migration、rollback 與 characterization tests——**不需要手動 migration**：這是
      全新的表，`db/init_db.py` 既有的 `SQLModel.metadata.create_all` 下次啟動就會自動
      建表（這個 repo 本來就只對「既存表新增欄位」才需要手動 `ALTER TABLE`，新表不用）；
      沒有對 production `running.db` 執行任何寫入或 schema 變更，純粹加 model 定義，
      行為等到下次正常啟動 app 才會生效。新增 `tests/test_analysis_run_model.py`
      （5 個 characterization tests，沿用這個 repo既有的 in-memory
      `sqlite+aiosqlite:///:memory:` + `async_sessionmaker` 慣例）：新表能跟既有表一起
      `create_all`、單一 RunSession 能同時掛兩筆 AnalysisRun（Compare 情境，互不覆寫）、
      相容性函式的三種情境（有/沒有真實 row、從未分析過）都驗證過。
- [x] 既有 Server 結果透過 compatibility adapter 表現成一筆 Server AnalysisRun
      （`synthesize_legacy_server_run()`，**只在記憶體中合成、不寫回 DB**：沒有真實
      `AnalysisRun` row 但有 `AnalysisMeta` 的舊 session，合成一筆暫態的 `compute_location="server"`
      紀錄；已有真實 row 時回傳 `None`，由呼叫端改用真實資料，不會被合成結果蓋掉）。

**完成條件：已達成（2026-10-04）。** `pytest -q`（`yolo_new` 環境，`PYTHONPATH=.`）
**19 passed**（14 既有 + 5 新增），沒有任何既有測試壞掉。`RunSessionInfoOut` 等 API
回應模型是獨立的 Pydantic class，不是直接序列化 ORM model，所以新增 relationship
欄位不會意外外洩進現有 API 回應。

### Step 10 — Backend Local ingestion 與 Compare 保存

- [x] **主要 repo：** `running-analysis-backend`。
- [x] 新增建立 Local run、上傳 manifest/artifacts、finalize、查詢 run 的 endpoints
      （`routes/analysis_run.py`：`POST /analysis_run/local`、
      `POST /analysis_run/{id}/manifest`、`GET /analysis_run/{id}`）。**刻意不呼叫
      `runner-analysis-pipeline`**，只接收並儲存已經算好的結果。
- [x] 驗證 schema、hash、ownership、camera count 與 idempotency key
      （`utils/contract_v1.py` 直接對 `runner-analysis-pipeline/contracts/analysis/v1/*.schema.json`
      做 `jsonschema` 驗證，不在 backend 複製一份 schema；逐一 artifact 重算 sha256/size
      比對 manifest 宣告值；ownership 透過 `run_session.runner.user_id` 檢查；
      `idempotency_key` 相同且該 run 已有結果時直接回放，不重新處理也不重複建立
      `AnalysisMeta`）。「必要 artifact」沒有另外發明比 contract schema 更嚴格的規則——
      schema 本身沒有 `minItems`，空 `artifacts` 陣列合法，因為 V1 必須輸出範圍已經在
      Step 1 定案在「本期目標」裡，不在這一步重新收斂。
- [x] 新增 comparison group 與 `ComparisonReport` 保存／查詢
      （`db_models/comparison_report.py` + `POST /comparison_report`、
      `GET /comparison_report/{comparison_group_id}`，對 contract v1
      `comparison-report.schema.json` 驗證後原樣存 payload）。**實際的數值差異計算
      （bbox/joint/速度 delta 等）這一步刻意沒做**——那需要 Local 真的有 2D/3D 輸出才能
      比對，依賴 Step 6-8/15-18，目前只做「儲存與查詢」這個 plumbing，之後誰算出
      diff 都能呼叫同一組 API 存進來。
- [x] 任一 run 失敗時保留另一筆成功結果並標記 partial——**解法**：發現 Step 9 的
      `AnalysisMeta`（1:1 綁 `run_session_id`）跟 Compare 模式（一個 RunSession 下兩筆
      `AnalysisRun`）結構上衝突，兩筆結果不可能同時安全寫進同一個 `AnalysisMeta` row
      而不互相覆寫。解法是幫 `AnalysisRun` 加一個 `result_summary`（JSON）欄位，每筆
      run 自己保存自己的 summary，永遠不衝突；`AnalysisMeta` 只在**非 Compare**
      （`comparison_group_id is None`）且該 RunSession 只有一筆 run 時才同步更新，
      避免「兩筆結果該聽誰的」的歸屬問題。Compare 情境下兩個 run 各自獨立成功/失敗，
      互不影響對方（已用測試驗證）。

**完成條件：已達成（2026-10-04）。** 新增 `tests/test_analysis_run_ingestion.py`
（6 個 tests，沿用既有「直接呼叫 route function」慣例，不經 HTTP TestClient）：
建立 Local run → 上傳合法 manifest → 標記完成且正確 mirror 進 `AnalysisMeta`；
camera count 不符會被拒絕；artifact 內容跟宣告的 sha256 對不上會被拒絕；重送相同
`idempotency_key` 會回放既有結果、不重複建立 `AnalysisMeta`；Compare 情境下兩筆
run 的 `result_summary` 互不覆寫、也都不會誤觸 `AnalysisMeta`；`ComparisonReport`
送出/查詢/重送更新都正確。`PYTHONPATH=. pytest -q`（`yolo_new` 環境）
**25 passed**（19 既有 + 6 新增），`main.py` 可正常 import、5 條新路由都正確掛載
在 `/running_analysis/api/` 下。

### Step 11 — Flutter 分析 seam 與三種模式

- [x] **主要 repo：** `running-analysis-frontend`。
- [x] 新增 `AnalysisMode.server/local/compare`、`AnalysisRequest`、`AnalysisEvent` Dart types
      （`lib/feature/analysis/{analysis_mode,analysis_request,analysis_event}.dart`；
      `AnalysisRequest.videos` 的 `anchors` 改成逐相機欄位，對齊
      `upload_all_view.dart` 實際呼叫 `uploadAllInfo` 時每支影片各自帶
      `anchorResult` 的既有結構，不是文件原先暗示的單一 request 層級欄位）。
- [x] 新增 `AnalysisExecutor` interface、`ServerAnalysisAdapter`、`LocalAnalysisAdapter`
      與協調邏輯（沒有另外叫 `CompareAnalysisCoordinator` class，而是直接做成
      `AnalysisRunController extends StateNotifier`，三種模式共用同一個
      controller——跟 §4 說的「coordinator 依 AnalysisMode 選擇一個 adapter，或在
      compare 模式協調兩個 adapter」等價，只是用這個 repo 既有的 Riverpod
      `StateNotifier` 慣例實作，不是獨立一個 coordinator 類別）。
  - `ServerAnalysisAdapter` 是**真的**包裝現有 `BackendInterface.uploadVideo`/
    `uploadAllInfo`，沒有另外寫假資料——這段不需要 native，Linux 上就能正確實作。
  - `LocalAnalysisAdapter` 是誠實的 stub：立即回報 `failed`，說明原生橋接
    （Step 12，依賴 Step 6-8 的 Swift 工作）還沒存在，**不是**測試用的假物件。
- [x] 先使用 fake/in-memory adapters 驗證狀態機，不立刻接 UI 或 native
      （`test/analysis_run_controller_test.dart` 用 `FakeAnalysisExecutor`，刻意不用
      真正的 `LocalAnalysisAdapter`——因為它必敗的行為會讓 Compare 測試無論 controller
      邏輯對不對都「看起來像」partial success，測不出真正的狀態機邏輯）。
- [x] 定義雙進度、取消、partial success、retry 與 result navigation 行為——
      `AnalysisRunState` 對 server/local 各自獨立保存 `SideProgress`（雙進度）；
      `cancel()` 只取消還在跑的那一側，已終結的一側不受影響；`isPartialSuccess`
      只在 Compare 模式且兩側都終結、且成功與否不同時才成立；`retryFailedSide()`
      只重跑失敗的那一側，成功的一側完全不動（這四項都各有獨立測試覆蓋）。
      Result navigation（導頁）留給 Step 13——那需要真正的畫面，這一步只確保
      `AnalysisRunState` 暴露了導頁需要的 `runSessionId`。

**完成條件：已達成（2026-10-04）。** 新增 `test/analysis_run_controller_test.dart`
（8 tests，涵蓋三種模式各自驅動正確的 executor、Compare 配對
`comparisonGroupId`、partial success 判定、cancel 不影響已完成的一側、
retry 只動失敗的一側、provider 能正確組裝真正的 adapter）。
`flutter analyze lib/feature/analysis test/analysis_run_controller_test.dart`：
0 issues。`flutter test --concurrency=1`（Linux 上預設的平行測試會讓多檔案
output 在終端機 pipe 裡交錯/遺失，不是真的測試沒跑，用 `--concurrency=1`
確認跑好跑滿）：全部 8 個測試檔案、**28 passed**，沒有任何既有測試壞掉。

### Step 12 — 完成 typed Flutter ↔ iOS bridge

- [x] **主要 repo：** `runner-pose-ondevice` 的 Flutter plugin與 `running-analysis-frontend`。
- [x] 以 Pigeon 定義 typed messages，傳遞 path/URL、request、stage events、typed failure、
      cancel、dispose 與完成 bundle path。
- [x] 新增 `RunnerPoseKit.podspec`／`RunnerAnalysisKit.podspec`，Flutter plugin 正式依賴
      `RunnerAnalysisKit`；host、pods、plugin deployment target 統一為 iOS 16。
- [x] 不透過 Dart `Uint8List` 搬運完整影片或大型結果；原生端以 1 MiB chunks 計算影片
      SHA-256，完成只回傳 bundle filesystem path。
- [x] 原生分析使用 iOS background task；到期會要求 engine 取消。取消、typed engine error、
      plugin dispose 均已接線。

**完成條件：已達成（2026-10-08）。** plugin 的 3 個 tests、
frontend 全部 38 個 tests 均通過；本次修改涵蓋的 Dart analyzer 為 0 issues，Ruby 語法檢查亦確認
三份 podspec 合法。Mac 已完成 CocoaPods/iOS build，iPhone 真機能透過 typed bridge 完成
Local 分析並收到完成事件；先前 native event thread 問題亦已改為由 main dispatch queue 傳送。

### Step 13 — 跑通單影片 Local 垂直切片

- [x] **修改 repo：** `runner-pose-ondevice`、backend、frontend。
- [x] 在 internal feature flag 下接上 Upload All 的單影片開發路徑。
- [x] 完成：選檔 → Local 2D → bundle → backend ingestion → 既有結果頁。
- [x] Local 完成後將原始影片與 result bundle 一起上傳；backend 保存影片供既有回放 endpoint 使用，
      不呼叫 Server pipeline 重算。
- [x] 失敗時提供 retry Local 或經確認後 switch Server。

**完成條件：** 真機能完成一筆 Local RunSession；歷史頁可辨識 `compute_location=local`；錄影流程完全未改。

**完成條件：已達成（2026-10-08）。** Upload All 在
`ENABLE_LOCAL_ANALYSIS=true` 時顯示 Server／Local 選項，預設仍為 Server；Compare 另由
`ENABLE_COMPARE_ANALYSIS` 控制，在 Step 14 完成共用 RunSession 與 ComparisonReport 前預設關閉。
Local 選檔使用 path-only staging（`withData: false`）；原生完成後將 manifest/artifacts 與所有
原始輸入影片以 multipart 串流同步至 Local ingestion endpoint。backend 會驗證影片 SHA-256，
將影片保存到該 RunSession 的既有 `cam<N>.<ext>` 路徑供回放，但不啟動 Server pipeline。
Local 同步失敗會保留裝置上的 bundle，並提供重試或經確認後切換 Server；切換 Server 是新的
運算選擇，不能因 Local 失敗而自動觸發。歷史列表會以 backend 回傳的
`computeLocations` 標示 `LOCAL`。Upload Separate 與 Record 沒有接入 analysis mode。

目前 frontend 38 個 tests、backend 34 個 tests 全數通過；Flutter analyzer 沒有 error/warning，
另有 35 個既有 info 級 lint。使用者已在 Mac/iPhone 完成 Local 選檔、YOLO/HRNet 運算、bundle
同步、影片回放與結果頁導覽驗收，並確認符合目前標準；錄影流程仍維持 Server-only。

### Step 14 — 跑通 2D Compare 垂直切片

- [x] **修改 repo：** frontend、backend 與本規劃書；pipeline/on-device 的數值差異輸出仍待後續子項。
- [x] 同一 request snapshot 建立 Server/Local 兩筆 runs 與同一 comparison group，並掛在同一個 RunSession。
- [x] Server 完成影片登記並建立共用 RunSession 後再啟動 Local；上傳選檔路徑會先複製到穩定 staging。
- [ ] 完整記錄 upload、server compute、local compute 與 end-to-end timings。
- [x] 實作 bbox、frame mapping、2D joint/confidence delta 報告，輸入 hash 不同時明確標示不可比較。
- [x] UI 顯示 Server／Local 兩條獨立進度，controller 保留 partial success 與單側 retry 狀態。

**完成條件：** 同一影片能看到兩份未覆寫結果與 2D ComparisonReport；input/config hashes 一致。

**實作狀態（2026-10-08）：進行中。** Compare 現在把 `comparisonGroupId` 傳入既有 Server
upload，backend 會先在該 RunSession 建立 Server `AnalysisRun`；Local ingestion 再依同一 group
找到並重用該 RunSession，而不是建立第二筆 session。frontend 等 Server 建立 session 後才啟動
Local，並顯示雙進度。Server backend 已改走 `run_analysis_with_manifest`，會在正式分析輸出目錄
發布 canonical manifest 與既有 pose2d artifacts。backend 已加入 Server H36M17 NPZ／offsets 與
Local WholeBody23 JSON 的座標轉換及 `(camera_index, source_frame)` 對齊，計算 bbox IoU、frame
match、H36M17 與 raw WholeBody23 的 2D mean/median/p95 pixel delta、confidence delta，以及
foot6 的獨立 pixel delta；兩側完成時自動保存 ComparisonReport。Server 會額外發布與 Local
同格式的 `pose/keypoints_2d.json`（23 點、原始影片座標、0-based camera index、明確 source
frame），既有 H36M17／foot NPZ 與 MotionAGFormer 流程維持不變。
結果頁會顯示報告或清楚提示 Server 尚未完成並提供重新整理。尚缺 upload/server compute/local
compute/end-to-end 的完整分段 timings 與共用 config snapshot hash，因此本 Step 尚未宣告完成。

**實作狀態（2026-10-13）：模型可追溯性已補上，尚未有任何一筆真機 Compare。** Local manifest 的
`engine.models` 先前寫死為空陣列，ComparisonReport 無法證明兩側用了哪些模型；現在 Local 會記錄實際載入的
`yolo26l`、`HRNetRunnerWholeBody23`、`MotionAGFormerLarge243` 資源 sha256 與 compute units
（`.mlmodelc`／`.mlpackage` 目錄以排序後的 `相對路徑\0檔案sha256` 雜湊），真機 RunSession
`66cac8ee` 已驗證三筆皆寫入。Server 端早已記錄模型 sha256（`_model_descriptors`）。backend 資料庫目前
`comparison_report` 仍為 0 筆，第一次真機 Compare 是本 Step 下一個驗收動作。

### Step 15 — 多相機 tracking parity

- [x] **主要 repo：** `runner-pose-ondevice`；fixtures 來自 pipeline。
- [ ] 實作 camera order、prescan ranges、主跑者選擇、interpolation、frame map、bbox map 與 offsets 語意。
- [x] 先完成 path-based sequential/bounded processing，禁止把多支影片全載入記憶體。
- [ ] 對 golden sessions 比較 bbox IoU、frame selection、camera transition 與 track identity。

**完成條件：** tracking gate 通過；沒有 frame drift、camera index 偏移或背景人物跳轉回歸。

**實作狀態（2026-10-08）：進行中。** Upload All 的 Local request 已能帶入全部選取影片，
原生 adapter 會先依 `camera_index` 排序，再使用同一組已 warm-up 的 YOLO26l／HRNet engine
逐支影片分析；任何時間只讀取一支影片的 frame stream，不會把多支影片或整部影片載入記憶體。
輸出的 `keypoints_2d.json` 會在每個 frame 保存 `camera_index` 與原始 `source_frame`；多相機共用
artifact 不會誤標為單一相機。多相機 overlay 仍明確延後至 Step 19。尚未完成的部分是與 Server
two-pass tracker 相同的跨 gap interpolation、跨相機 runner identity／transition，以及 golden
session 的 bbox IoU 與 frame map gate，因此本 Step 尚未宣告完成。

**補充（2026-10-13，Local anchor ROI）：** 先前 calibration 的 `start_line`／`end_line`／ROI 只供
速度與 homography 使用，沒有傳入 `RunnerPoseKit`，因此 Local 仍可能選到錨點區域外的人並畫出骨架。
現在每台相機會由起點／終點錨點建立與 Server 相同的跑道方向投影：prescan、fresh detection 與
tracker extrapolation 都使用 bbox 底部中心點，接受範圍為起點前 200 px 至終點後 120 px；開始前
優先選最接近起點的人，連續三幀投影單調前進才確認起跑，保留最多五幀 pre-roll，抵達終點線後
輸出該幀並重置 tracker。這完成 Local 單相機 ROI 狀態機對齊；跨相機 identity、interpolation 與
Server golden tracking gate 仍待完成。

### Step 16 — 2D 正式後處理 parity

- [ ] **主要 repo：** `runner-pose-ondevice`。
- [ ] 依序移植 COCO→H36M、foot split、confidence/status masks、SG smoothing、bbox normalization、bone/anatomical corrections。
- [ ] 每次只移植一個數值 stage，對應一組 fixture test。
- [ ] foot 六點維持 Server 現行 raw/unsmoothed 語意，除非共同 contract 升版。

**完成條件：** 所有 2D stage tests 通過 provisional tolerance；整體 Compare 報告沒有未解釋的系統性偏差。

**實作狀態（2026-10-08）：已完成第一個資料 seam。** Server 在 COCO→H36M 前保留 HRNet
原始 WholeBody23，並透過 tracking offsets/frame map 額外發布與 Local 相同 shape 的
`pose/keypoints_2d.json`；manifest 會將它登記為 pose2d artifact，ComparisonReport 可直接比較
完整 23 點與 foot6。這是新增 canonical artifact，不會取代既有 `keypoints.npz`（H36M17）或
`foot_keypoints.npz`（raw foot6）。其餘 confidence/status masks、SG smoothing、bbox normalization、
bone/anatomical corrections 的數值 parity 仍待逐項移植與 golden gate。

### Step 17 — 3D 與角度正式整合

- [ ] **主要 repo：** `runner-pose-ondevice`。
- [ ] 將 Step 5 通過的 243-frame large/H36M Core ML 模型包成內部 3D runner；模型缺失或裝置
      不支援時回傳明確 capability stage（目前為 skipped + degraded），不允許以空陣列假裝成功。
- [ ] 依序實作 WholeBody23→H36M17、sequence window、resampling/padding、screen normalization、
      flip augmentation／unflip averaging；每個純數值階段各有 Server fixture。
- [ ] 從 H36M17 3D 計算膝、髖、手臂軀幹、手肘、肩膀與骨盆軀幹角度，再移植 supplementary
      knee correction 與時間平滑；原始角度與修正後角度都需可追溯。
- [x] 輸出 `pose/keypoints_3d.json` 與 `angles.json`，登記 artifact hash，接入 result bundle 與
      ComparisonReport。
- [ ] 測量 ANE/GPU/CPU fallback、記憶體與 thermal。

**完成條件：** 3D joints/angles 通過 golden gate；不支援裝置得到明確 capability 結果，不產生假成功 3D artifact。

**實作狀態（2026-10-12）：核心垂直切片、Mac 編譯與真機 gate 已通過，尚待數值 parity。** 已新增
`MotionAGFormer3DProcessor` 與可替換 predictor seam，完成 WholeBody23→H36M17、243-frame
resampling/padding、screen normalization、flip/unflip averaging、原始 frame/camera/time identity 還原，
並依 Server 公式計算角度、supplementary knee correction 與 FPS-adaptive Savitzky-Golay 平滑。
`RunnerAnalysisEngine` 現在會在 pose2d 後執行 pose3d；bundle 會寫入
`pose/keypoints_3d.json`、`angles.json` 及對應 hash。角度同時保留 `raw_values_degrees` 與
`values_degrees`，可追查修正前後差異。若模型尚未放入資源，manifest 會明確把 pose3d 標為
`skipped` 且整體維持 degraded，不會以空 3D 陣列假裝完成。

Backend ingest 已將 canonical `angles.json` 產生為既有結果 API 可讀的衍生 `angles.csv`，因此
Local 同步後的角度可沿用現有 graphs／angles／report endpoint。Backend 全套測試目前為
36 passed。Mac 已完成 24 項 RunnerAnalysisKit 測試、iOS debug build，真機也已完成實際 Core ML
large/243 推論與 bundle 同步。尚未通過的項目是：Server golden fixture 數值比較、ANE fallback／
記憶體／thermal，以及 Step 18 leg identity 在 3D 前修正的最終資料順序。

**補充（2026-10-13）：** 真機 `IMG_0247.MOV`（1197 幀）輸出 2D 240 幀、其中 valid 186 幀，3D 也是
186 幀；3D 只處理 valid 2D frame，兩者數量不同屬預期，但 3D／角度數值比較必須以
`(camera_index, source_frame)` 對齊，不能以 array index 對齊。

**補充（2026-10-13，backend 比較器）：** ComparisonReport 已加入 3D joint frame match、MAE、P95，
以及角度 frame match、MAE、P95。Server `3Dkeypoints.npz`／`angles.csv` 與 Local canonical JSON
均透過 offsets 中的 `(camera_index, source_frame)` 對齊，不以 array index 直接配對；backend 全套
測試 36 passed。現有 tolerance 先明確標記為 provisional，需由第一次同輸入真機 Compare 的
實測分布校準，因此本 Step 的數值 parity gate 仍未通過。

### Step 18 — 速度、leg identity 與 gait parity

- [ ] **主要 repo：** `runner-pose-ondevice`。
- [ ] 先移植逐幀 bbox center／bottom-center 軌跡與 frame/time mapping，再加入 pixel fallback、
      homography 世界座標、跨相機距離累積、Butterworth/Kalman 與 confidence；禁止只用 array index
      推算時間。
- [ ] 移植 leg identity DP，輸出每幀左右腳 assignment、swap confidence 與 correction reason，
      並確保它發生在 3D lifting 與角度之前。
- [ ] 在固定 leg identity 後移植 touchdown、heel/toe/contact，再組成 step/stride 與 long-jump
      takeoff/landing 分支；接觸事件必須帶 source frame、camera index、時間與 confidence。
- [ ] 每個 stage 使用獨立 fixture 與 summary/event comparison。

**完成條件：** 速度、事件、左右腳、步幅與 summary metrics 通過核准門檻；缺校正時的 fallback 與 Server 一致。

**實作狀態（2026-10-12）：正式距離／速度／加速度垂直切片已完成，待 Mac／真機數值 gate。**
`KinematicsTrajectoryBuilder` 已從原始影片 bbox 產生 center／bottom-center，逐筆保留
camera/source frame/timestamp，並實作 start/end line 自動 homography、明確控制點 homography
投影，以及與 Server 相同的 extrapolated-gap confidence 0.7／0.4／0.2 分級；對應 fixture 已加入
Mac test target。`ServerAlignedKinematicsProcessor` 已依 Server 順序加入 monotonic constraint、flat
segment interpolation、3.5 Hz 二階雙向 Butterworth、constant-acceleration Kalman 與跨相機 continuity。
Local bundle 會寫入 canonical `metrics.json`，summary 會帶平均速度與平均加速度；無校正資料時
speed stage 明確標為 skipped，不輸出假資料。

Backend ingest 會把 hashed `metrics.json` 衍生成既有 graphs／report endpoint 使用的 `metrics.csv`，
不會重新執行 Server pipeline。Local ingestion 全檔測試為 11 passed；Swift 端已加入 Server
characterization golden 數值與跨相機 continuity 測試，仍須在 Mac 跑過後才可勾選本 Step 的
距離／速度／加速度 gate。Compare report 也已加入依 `(camera, source_frame)` 對齊的 frame match、
distance MAE、speed MAE 與 acceleration MAE，供同影片真機測試直接判讀差異。

Flutter↔iOS typed bridge 也已補上 `analysisKind`、每相機 calibration、ROI 與 kinematics policy。前端會把 `AnchorResult`
的 normalized 4/6 點換回原始影片 pixel，連同 world metre points、start/end line 與總距離傳入
`AnalysisRequest`；原生端不再把所有 Local 工作固定成 `running`，lane width 也不再固定為 1.22 m。plugin 與 frontend 的 bridge
測試均已通過。

Canonical request 現已包含 `roi_x`／`roi_y` 與 `speed_mode`、Butterworth cutoff、flat interpolation
epsilon、lane width；Local 與 Server 可以以同一份顯式設定重現速度結果。Backend 會依 artifact
type 驗證 canonical kinematics、leg identity、contact、steps 與 long-jump JSON，不符合 schema 時
以 422 拒絕，不讓格式錯誤延後到結果頁才爆發。這一項完成的是 contract 與傳輸鏈，不代表
leg identity／contact／step 演算法已完成。

Step 17 已保留 camera/source frame/time，可作為本 Step 的時間軸 seam；但 Server 的速度不是單純 frame 差分，而是 bbox 原圖座標、
pixel/homography 雙模式、跨相機 continuity、Butterworth 與 constant-acceleration Kalman 的組合。
因此在 golden fixture 建好以前，不以簡化速度公式填入正式欄位。實作順序固定為：

1. [x] bbox bottom-center／center 與 source time fixture。
2. [x] homography 投影 fixture；canonical contract、Flutter bridge 與 Swift request 已補 ROI。
3. [x] monotonic/interpolation、Butterworth、Kalman、跨相機 continuity 實作與 fixture；待 Mac golden gate。
4. touchdown 初始錨點與 leg-identity DP；修正 WholeBody23／foot6 後重新執行 3D 與角度。
5. heel/toe/contact、step/stride、long-jump takeoff/landing 與 summary/artifact/API 串接。

**實作狀態（2026-10-13）：真機發現 Local 從未取得校正資料，已修正，待 Mac／真機重測。**
2026-10-12 真機 Local（RunSession `66cac8ee`）speed stage 為 `skipped`，原因是 Local 一直拿不到 calibration：

- [x] **Local 不會出現錨點頁。** Local 選檔只 stage 不上傳，沒有 Server thumbnail，錨點 dialog 永遠不開。
      修正：runner_pose 新增 `extractFirstFrame`（`AVAssetImageGenerator`，套用 preferred transform，
      對應 Server cv2 thumbnail 的第一幀）；Upload All 在 Local 選檔後讀第一幀並開同一個錨點 dialog，
      dialog 改收 `ImageProvider`（Server `NetworkImage`／Local `MemoryImage`）。
- [x] **即使有錨點也會失敗。** Upload All 傳 `frameWidth/frameHeight = 0`，前端用 0 換算正規化錨點而丟出
      「影片寬高必須大於零」。測試用 1920×1080 所以沒抓到。修正：calibration message 新增
      `imagePointsNormalized`，前端傳正規化點，plugin 以原生讀到的 oriented 影片尺寸換算成像素。
- [ ] Swift `swift test`（含 Server golden kinematics）與真機帶錨點 Local：speed stage `completed`、
      `metrics.json` 速度合理。
- [ ] 同影片 Compare 的 distance／speed／acceleration MAE。

已知限制：錨點 dialog 固定 16:9 + `BoxFit.cover`，直向影片的錨點位置會偏移（Server 同樣如此）。

### Step 19 — Overlay、完整 Upload All 與發布 gate

- [ ] **修改 repo：** `runner-pose-ondevice`、backend、frontend。
- [ ] 產生 V1 正式要求的 main/per-camera overlays、CSV/PDF 或其 canonical data source。
- [ ] 完成大型 artifacts 的續傳、hash、retry 與清理。
- [ ] Upload All 正式接 Server/Local/Compare；Upload Separate 與 Record 繼續 Server-only。
- [ ] 執行完整裝置矩陣、長影片 memory、thermal、低磁碟、background、取消與斷線測試。
- [ ] 先 internal flag，再 device allowlist／比例發布；保留 Server fallback。

**完成條件：** P0–P6 gates 全部通過；結果頁功能一致；Compare 可追溯差異；Local／Compare 在
開始前明示影片同步行為，且不存在 Local ingestion 意外觸發 Server 重算的路徑。

### 建議現在開始的位置

目前 Step 0–13 已完成並通過 Local 真機垂直切片驗收；Step 14 的共用 RunSession、2D
ComparisonReport 與結果頁已完成，尚待完整 timings/config snapshot gate；Step 15 已跑通多相機
path-based 循序分析骨架。2026-10-08 起可並行建立 Step 17 的 MotionAGFormer 深模組與純數值
fixtures，但正式 3D golden gate 仍依賴 Step 16 的 H36M17／leg identity 輸入語意鎖定；其後依序
完成角度、速度／距離、leg identity、gait/contact 與 Step 19 發布 gate。

**2026-10-13 更新：** 下一步依序為 (1) Mac `swift test` 與真機帶錨點的 Local，確認 Step 18 第 1–3 項的
speed gate；(2) 同一影片第一次真機 Compare，取得 Step 14 的 2D、3D、角度與速度差異數據，並以
實測分布校準 provisional tolerance；(3) Step 16 2D 後處理；(4) Step 18 leg identity。
Mac 操作指令見 `docs/mac_verification_commands.md`。

**2026-10-13 Local overlay 修正：** Local overlay 已套用 Server 色盤：左側身體線為藍色、右側
身體線為紅色、身體關節為綠色、左腳六點／連線為黃色、右腳六點／連線為洋紅色。ROI 狀態機與
色盤的 Swift regression tests 已加入，需在 Mac 執行後完成真機畫面驗收。
