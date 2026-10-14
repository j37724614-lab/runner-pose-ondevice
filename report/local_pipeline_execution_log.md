# Local / Server Pipeline Execution Log

本文件記錄 `report/integration_guide.md` 第 13 節逐步執行清單的實際結果。所有時間使用
Asia/Taipei；既有 dirty worktree 全部視為使用者工作，不在本計畫中清理或覆寫。

## Step 0 — 起始基準

狀態：**進行中**。Linux baseline 已完成；Mac、Xcode、iPhone BenchApp baseline 待補。

記錄日期：2026-10-04

### Host 與工具

| 項目 | 基準 |
|---|---|
| Host | `catslab`, Ubuntu kernel `7.0.0-31-generic`, x86_64 |
| CPU | Intel Core Ultra 7 265KF, 20 logical CPUs |
| RAM | 125 GiB；記錄時 available 81 GiB |
| Python | 3.13.2 |
| pytest | 9.0.2 |
| Existing test env | conda `yolo_new`: Python 3.11.6，包含 pytest/bcrypt/torch/OpenCV |
| Flutter | 3.44.0 stable, revision `559ffa3f75` |
| Dart | 3.12.0 stable |
| Swift/Xcode | Linux host 無可用工具；Mac build log 顯示 Xcode build `17F113`、iPhoneOS SDK 26.5 |

注意：`runner-analysis-pipeline/requirements.txt` 指定 Python 3.11.15；本次 Python 3.13.2
結果只作為目前 Linux host baseline，不能取代正式 3.11 環境驗收。

### Repo 基準

`status sha256` 是執行 `git status --porcelain=v1 | sha256sum` 的結果，用來辨識此次基準時的
worktree 集合；它不是 source commit hash。

| Repo | Branch | HEAD | Dirty 摘要 | status sha256 |
|---|---|---|---|---|
| `runner-pose-ondevice` | `main` | `2217f027e571fecd64b643bfeee356d9047e1203` | 4 tracked changes | `1f50d29c06cc6a1616cc7b6536cc9f2e0b3ce4fd52bb65d7ec105a95b39717d4` |
| `runner-analysis-pipeline` | `main` | `97e7fac3dae17fbc12853a885f39f2431dbe1ce9` | 31 tracked changes，其中 14 deleted；97 untracked | `3e58e30d9a45f0fa27f12a28a41d047c005bd90c0e7c1115d77647595333f488` |
| `running-analysis-backend` | `jeter-dev` | `de0b1c279c3059b16aca7688bc0ef3b216a24e1b` | 12 tracked changes；4 untracked | `5409f3bf1ad6d8301fe8eeb8ecafd4bdeb5c78bc367bc6f9c049c59c9310cdbb` |
| `running-analysis-frontend` | `integrate/f413c3c` | `1699d3aa68fa5c4328cfab1ff2f2b4688a7da838` | 5 untracked | `3a6f7fd794ba6e7c816f207a072fac3bbba0f2336a21791dcf13861357d18762` |

測試期間沒有修改 frontend `pubspec.lock`。`.dart_tool`、Python cache 等 ignored artifacts 不納入
dirty 摘要。

### 正式模型基準

目前 Server 程式預設指向以下模型：

| 用途 | 檔案 | SHA-256 |
|---|---|---|
| Tracking YOLO | `runner-analysis-pipeline/models/yolo26x.pt` | `9fdd44a31c504547ffb81d2c6d9e6dac3493c8eaa8b0398d3f43bae6c7003e92` |
| WholeBody-23 HRNet | `data/runner_wholebody23/exports/pose_hrnet_w48_wholebody23_384x288_dark_jump_broadcast_long_triple_pilot300_headonly_epoch3.pth` | `6beb54da8c0c3d98f93694874bbe7684c6aa3c581fa5b9a8685e369feaffb6f3` |
| MotionAGFormer 3D | `MotionAGFormer/checkpoint/motionagformer-s-ap3d.pth.tr` | `abae77098857c338a8a48a35abdb1c300556ff776d06ef217569f0ae030fd230` |

`runner-pose-ondevice` Linux checkout 目前只有 `models/yolo/yolo26{n,s,m,l,x}.pt` staging files，
沒有可供 iOS package 直接載入的 `.mlpackage`／`.mlmodelc`。Core ML resource 與 hash 待 Mac
工作區確認。

### 測試結果

| Repo | 指令 | 結果 |
|---|---|---|
| Pipeline | `pytest -q` | collection failed：誤收集 vendored AthletePose3D/MogaNet tests；49 errors，缺 `mmcv`、`mmhuman3d`、`pytorch3d`、`simvp`、`spm1d` 等 |
| Pipeline | `pytest -q tests` | **164 passed in 12.40s** |
| Pipeline | `yolo_new/bin/python -m pytest -q tests` | **164 passed、3 warnings in 12.15s**；Python 3.11.6 |
| Backend | `pytest -q` | collection failed：project root 未在 import path；4 errors |
| Backend | `PYTHONPATH=. pytest -q` | collection failed：缺 `bcrypt`；2 errors |
| Backend | `PYTHONPATH=. pytest -q tests/test_database_migrations.py tests/test_upload_anchor_contract.py tests/test_cleanup.py` | **2 passed、6 failed**；6 failures 均由缺 `bcrypt` 引起 |
| Backend | `PYTHONPATH=. yolo_new/bin/python -m pytest -q` | **14 passed、1 warning in 1.99s**；Python 3.11.6 |
| Frontend | `flutter analyze` | 35 個既有 info、0 warning、0 error；tool 因 info 回傳 exit 1 |
| Frontend | `flutter test` | **20 passed** |
| On-device Swift | `swift build` / `swift test` | 未執行：Linux host 無 Swift/Xcode，且 package 使用 Apple frameworks |
| BenchApp | Release iPhone benchmark | 未執行：需要 Mac、Xcode、Core ML resources 與實機 |

### Mac Release build 補充紀錄

使用者提供的 2026-10-04 Mac 終端輸出執行：

```bash
xcodebuild \
  -scheme BenchApp \
  -project BenchApp/BenchApp.xcodeproj \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  build
```

結果：**BUILD SUCCEEDED**。

- 目標：arm64、iOS deployment target 16.0、Release configuration。
- BenchApp、RunnerPoseKit、UltralyticsYOLO 均完成編譯與連結。
- App 完成 development code signing。
- Xcode 成功將下列 resources 編譯成 `.mlmodelc`：
  - `HRNetRunnerWholeBody23.mlpackage`
  - `yolo26n.mlpackage`
  - `yolo26l.mlpackage`
- 這能確認 package、模型資源與 Release iOS build 可以完成，但不代表單元測試或實機推論已通過。

Build log 中的非阻塞警告：

1. `yolo-ios-app` 同時以 GitHub dependency 與 local package 出現相同 package identity；SwiftPM
   表示未來版本會升級成 error，正式整合前必須只保留一種來源。
2. Scheme 曾輸出 `Supported platforms for the buildables ... is empty`，但本次 generic iOS build
   仍成功；應在 Xcode scheme/project 設定中確認 supported destination。
3. BenchApp 沒有支援所有 interface orientations，除非設定 requires full screen。
4. AppIntents metadata 被略過，因專案未使用 AppIntents；這項與 pipeline 無關。

### Mac 工具版本與 `swift test` 補充紀錄

使用者提供的 2026-10-04 Mac 終端輸出：

| 項目 | 結果 |
|---|---|
| macOS | 26.5.2（Build 25F84） |
| Xcode | 26.6（Build 17F113） |
| Swift | Apple Swift 6.3.3；`arm64-apple-macosx26.0` |
| `swift test` | **未通過**；macOS target 編譯 `UltralyticsYOLO` 時找不到 `UIKit` |

`swift test` 的關鍵錯誤：

```text
.build/checkouts/yolo-ios-app/Sources/UltralyticsYOLO/BasePredictor.swift:15:8:
error: no such module 'UIKit'
```

這是目前 package 的平台／dependency 邊界問題：`Package.swift` 宣告支援 macOS 以執行 parity
tests，但 `RunnerPoseKit` 直接依賴的 `UltralyticsYOLO` 使用 iOS-only `UIKit`，所以 SwiftPM 以
macOS host 執行測試時會在 dependency compile 階段失敗。這不推翻前一節成功的 generic iOS
Release build，也尚未執行到 `RunnerPoseKitTests` 本身。

另有一項非阻塞 warning：`Sources/RunnerPoseKit/Resources/README.md` 未明確宣告為 resource 或
exclude。正式修正測試架構時一併處理。

### iOS Core ML 來源模型 SHA-256

使用者於 Mac 對 `.mlpackage` 內所有檔案排序後逐檔計算 SHA-256，再對結果計算 package
composite hash。這些 hash 用來識別本次基準測試使用的來源模型；不是 Xcode DerivedData
內、可能隨 Core ML compiler 版本改變的 `.mlmodelc` hash。

| 模型 | Composite SHA-256 |
|---|---|
| `HRNetRunnerWholeBody23.mlpackage` | `d9377a55247a6675ce9b643a2e7a3eb4ed6d929669332c013077a76b0315c75b` |
| `yolo26n.mlpackage` | `0d460751781f311c13aabbbb8fdec25dac12d982838e0e8adcdc11ce10a711a4` |
| `yolo26l.mlpackage` | `732bb5253cab36f8ff79ab2b0cfd0cf985bf9ccaf0feeb020770ebf13fdfe855` |

### iPhone BenchApp 暫定 baseline（Debug / YOLO26L）

使用者提供三份 BenchReport：

- `87CD0191-A6AD-4417-B9DA-78BA1EAEFED9.json`（run 2）
- `6D318A5F-2F98-47C8-8D95-67D2C53D6CBC.json`（run 3）
- `64F74375-2049-4F0F-8D16-52FC3801FF9C.json`（run 4）

共同條件：使用者回報裝置為 iPhone 17、iOS 26.3、`IMG_0085.MOV`（727 frames、59.975 fps）、YOLO26L、detector
cadence 1、max in flight 3、3 warmups、naive variant、`MLComputeUnits(rawValue: 3)`、起始
battery 100%、起始 thermal nominal。三次都沒有 memory warning，thermal 全程維持 nominal。

> 注意：三份報告都明確記錄 `appBuild: debug`，而且 `deviceModel` 只記成 `iPhone`；因此這批
> 數據可作為穩定性與 Debug 參考，但不能取代規劃要求的「指定 iPhone Release baseline」。

| 指標 | Run 2 | Run 3 | Run 4 | 三次平均 |
|---|---:|---:|---:|---:|
| Effective FPS | 18.303 | 18.126 | 18.018 | **18.149** |
| Wall clock (s) | 26.225 | 26.481 | 26.640 | **26.449** |
| Prescan (s) | 1.915 | 1.873 | 1.935 | **1.907** |
| Detect mean (ms) | 21.692 | 21.966 | 21.864 | **21.841** |
| HRNet mean (ms) | 6.001 | 6.082 | 6.133 | **6.072** |
| Warp mean (ms) | 3.116 | 3.089 | 3.090 | **3.098** |
| Postproc mean (ms) | 26.498 | 26.922 | 27.301 | **26.907** |
| Peak memory (MB) | 269.800 | 270.425 | 337.909 | **292.712** |

FPS 範圍為 18.018–18.303（最大差 0.285 FPS），運算時間相當穩定；peak memory 第三筆升到
337.909 MB，後續 Release 重測仍需觀察是否重現。報告只保存起始 battery level，沒有結束
battery 或 energy consumption，因此目前不能宣稱已量到耗電量。

使用者另提供 `/home/jeter/runner-pose-ondevice/IMG_0085(1).MOV`，檔案 SHA-256 為
`6bb739898790333d0ed64065cd1f4f98ae476c6e28b5c475d572aea603dd623e`。但 `ffprobe` 顯示此檔案為
H.264、1280×720、364 frames、約 29.99 fps、12.138 秒，與上述 BenchReport 記錄的 727
frames／59.975 fps 不一致。兩者時長接近，可能是同一畫面的 30 fps 轉檔版本；在無法證明
byte-identical 前，此 hash **不得**當成三次 Debug run 的原始 input hash。它可在後續固定為一份
新的測試 fixture，但若 Release 重測改用此檔案，baseline 必須明確標示輸入已變更。

### 已知基準問題

1. Pipeline 沒有 pytest collection scope，直接 `pytest` 會進入 vendored repositories；目前可靠指令是 `pytest -q tests`。
2. Backend 測試需要 `PYTHONPATH=.`。Base Python 缺 `bcrypt`，但既有 `yolo_new` conda 環境可得到完整 **14 passed** 基準。
3. Frontend analyze 有 35 個既有 info，之後應以「不增加 error/warning，且不增加未核准 info」作為回歸標準。
4. Release iOS build 已成功；`swift test` 已執行但受到 iOS-only `UIKit` dependency 阻擋。
   模型 hash 已取得，Debug 實機資料也已保存；但 Release 實機數據、精確裝置型號、輸入影片
   hash 與 energy/battery delta 尚未取得，Step 0 因此不能標記完成。

### Step 0 剩餘工作

- [x] 在既有 Python 3.11.6 `yolo_new` 環境重跑 pipeline：164 passed。正式 requirements 註記的 3.11.15 仍需在部署環境確認。
- [x] 在既有完整依賴環境重跑 backend：14 passed。
- [x] 在 Mac 完成 BenchApp generic iOS Release build；`BUILD SUCCEEDED`。
- [x] 在 Mac 補記 macOS／完整 Xcode／Swift 版本，並執行 `swift test`；已知失敗為
      `UltralyticsYOLO` 使用 `UIKit`，無法針對 macOS target 編譯，測試本體尚未啟動。
- [x] 確認三個 iOS `.mlpackage` 實際檔案與 composite SHA-256；採來源 package hash，不採
      可能隨 Xcode/Core ML compiler 改變的 DerivedData `.mlmodelc` hash。
- [x] 保存三次 Debug／YOLO26L 實機 BenchReport 作為暫定參考；平均 18.149 FPS、292.712 MB
      peak memory、thermal nominal。
- [x] 擴充 BenchReport instrumentation：以 hardware identifier 取代泛稱 `iPhone`，並新增
      optional `power`（start/end/change）欄位；舊版無 `power` 的歷史 JSON 保持可解碼。
- [ ] 在 Mac 編譯並執行新增的 legacy JSON compatibility test；Linux host 無 Apple SDK，無法
      驗證 UIKit/Core ML target。
- [ ] 在 iPhone 17 以 Release 重跑 BenchApp，記錄實際輸入影片 hash、FPS、
      各 stage latency、peak memory、battery delta／energy 與 thermal。

### YOLO26X detector 補測（2026-10-14）

- 正式預設維持 `yolo26l`。
- BenchApp detector picker 與模型下載／staging 流程加入官方 INT8 `yolo26x.mlpackage`。
- `yolo26x` 只作為高精度候選；需用相同影片和 `cadence=1/3/6` 比較 bbox miss、bbox IoU、
  detect mean/p90、effective FPS、peak memory 與 thermal，不能只用 COCO mAP 決定正式模型。

## Step 1 — V1 產品決策

狀態：**已定案（除最低裝置門檻）**。記錄日期：2026-10-04。

| 問題 | 決策 |
|---|---|
| V1 必須輸出 | 維持 `integration_guide.md` 既有「本期目標」範圍（summary/metrics/angles/steps + 產品需要的 overlay），不額外收斂或放寬 |
| 模型佈署 | HRNet／YOLO／MotionAGFormer 一律版本化下載，首次使用時抓取，不內建進 App bundle |
| 原始影片稽核上傳 | 允許使用者選擇性上傳，但預設關閉，需手動勾選 |
| Upload All 限定 | 採納：Local／Compare 這次只支援 Upload All；Upload Separate 與錄影頁維持 Server-only |
| 最低 iPhone/iOS/時間/記憶體門檻 | **暫緩**，待本 Step 0 的 iPhone 17 Release baseline 數據回來後再定，不用 Debug 數據猜測 |

詳見 `integration_guide.md` 第 12 節與 Step 1 checklist。

## Step 2–4 — canonical contract / server manifest / golden corpus

狀態：**`runner-analysis-pipeline` repo 內已有實作**（非本次 session 完成，疑似由另一個並行
的 Claude Code session 在該 repo 完成；本次只做確認，未重新驗證內容）。

於 `/home/jeter/runner-analysis-pipeline` 確認存在：

- `contracts/analysis/v1/`：`README.md`、`analysis-request.schema.json`、
  `analysis-event.schema.json`、`analysis-result-manifest.schema.json`、
  `comparison-report.schema.json`、`fixtures/{valid,invalid}/`、
  `golden/{single_camera_leg_identity,multicamera_no_homography,edge_cases,tolerances.json,server_repeatability.json}`。
- `core/contracts/`、以及 `core/pipeline/{orchestration,pose_step,tracking_step}.py`、
  `core/pose_stream.py`、`MotionAGFormer/demo/{vis.py,lib/preprocess.py}` 均為 dirty/modified，
  指向 manifest adapter 已接進 `run_analysis()`。
- `integration_guide.md` 內 Step 2–4 已標記「完成條件：已達成」，引用 Server 完整測試
  185 passed。

**已完成獨立審查（2026-10-04）**，結論：schema／fixture／hashing／JSON round-trip 的部分
是紮實的（`jsonschema` 驗證真的有在跑，hashing deterministic、atomic write 正確），但發現
三個必須先處理的問題，已同步更新進 `integration_guide.md` 對應 Step 的完成條件：

1. **CRITICAL**：`MotionAGFormer/demo/vis.py`／`preprocess.py` 有未 commit、**無條件**生效
   的改動（3D checkpoint 從 large 換成 small、刪軀幹修正、改骨架連線），連現有 HRNet 正式
   路徑都受影響，違反「Server 現有結果不得因 Local 開發而改變」。Step 4 的 golden corpus
   是對著這個已變更的 pipeline 錄的，暫時不可信。`docs/experiments/moganet_e3_ap3d_body_ab_20261002.md`
   顯示這可能是另一條獨立實驗，只是混在同一個髒 worktree——需要確認意圖並拆成獨立 commit。
2. **HIGH**：Step 3 的 manifest adapter（`core/contracts/analysis_v1.py`）只被自己的測試
   呼叫，從未接進 `run_analysis()` 或 `analyze.py`；目前真實跑一次 Server 分析不會產生
   `manifest.json`。映射邏輯本身正確，只是沒接線。
3. **MEDIUM**：golden corpus 的 `pose2d_raw` 其實已經是 foot-split + COCO→H36M 重排之後
   的 17-joint 資料，不是真正的 HRNet 23-joint 原始輸出；schema 宣告的 `joint_order` 對
   不上實際資料，且 foot keypoints 與 body pose2d 共用同一個 `artifact.type`，無法區分。

測試實際結果（`yolo_new` 環境）：`pytest -q tests` → **192 passed**（非文件原寫的 185）；
`pytest -q tests/contracts` → **28 passed**。

**在這三項處理之前，不建議開始依賴 golden corpus 的 Step 5 以後工作**（Step 5 的 Core ML
spike 本身不直接依賴 golden corpus，可以先進行；但 Step 16 的 2D parity 必須等 raw/post
schema 修正後才能正確切分問題）。

### 後續處理（2026-10-04，同日）

- **問題 1（模型替換）**：使用者確認是自己平行測試用的改動，沒有動到主流程，**不視為
  阻塞**，不需要拆 commit 或重錄 golden corpus。
- **問題 2（manifest adapter 沒接線）**：已修正。新增
  `core.pipeline.run_analysis_with_manifest()`（`core/pipeline/final_export.py`），不修改
  `run_analysis()` 本身，純粹在呼叫端多做一步寫 manifest；`analyze.py` 的 demo 已改用新函式
  並帶上真實模型路徑（YOLO tracking / HRNet wholebody23 / MotionAGFormer）。新增兩個測試
  `tests/contracts/test_run_analysis_with_manifest.py`。`pytest -q tests`（`yolo_new` 環境）
  現在 **194 passed**。production 實際呼叫路徑在 `running-analysis-backend` 那邊，還沒接，
  留給 Step 9/10。
- **問題 3（raw/post joint schema 混淆）**：維持待辦，記錄在 `integration_guide.md` Step 2
  完成條件，排進 Step 16 之前處理，不阻塞現在往下推進。

## Step 5 — MotionAGFormer Core ML 可行性 spike

狀態：**已完成，結論 GO**。記錄日期：2026-10-04。完整細節見
`report/motionagformer_coreml_spike.md`；重點摘要：

- 官方 `MotionAGFormer-large`（n_frames=243）+ 使用者測試用 `small/ap3d`
  （n_frames=81）都能轉成 Core ML，前提是修正 `attention.py`/`ctr_attention.py`
  裡一個會讓 coremltools 直接報錯（rank-6 reshape）的 QKV reshape 寫法；修正
  已用數值比對驗證（patch 前後 `max_abs_delta = 0.0`），只套用在 spike 腳本裡，
  沒有改 `runner-analysis-pipeline` 任何檔案。
- `n_frames` 是靜態建圖參數，不是 dynamic shape——81 與 243 需要各自匯出固定
  shape 的模型，不能共用一份。
- 另外發現並繞過一個 coremltools 9.0 + NumPy 2.x 的相容性 bug（不是
  MotionAGFormer 特有）。
- Linux 上無法執行 Core ML 推論驗證數值，已存好 PyTorch 參考輸入/輸出
  （`report/motionagformer_coreml/*/`），等 Mac/iPhone 才能完成最後一項驗證。

## Step 6–8 — 暫緩（純 Swift，Linux 無工具鏈）

Step 6（`RunnerAnalysisKit` 外殼）、7（接入 `RunnerPoseEngine`）、8（Local result
bundle writer）都是純 Swift 工作，這台 Linux host 確認沒有 `swift` 指令
（`which swift` 無結果），沒辦法編譯驗證，故跳過、先做不依賴 Swift 的 Step 9，
等 Mac 環境可用時再回頭做。

## Step 9 — Backend 建立 `AnalysisRun` 資料模型

狀態：**已完成**。記錄日期：2026-10-04。`repo: running-analysis-backend`。

- 新增 `db_models/analysis_run.py`（`AnalysisRun` 表 + `synthesize_legacy_server_run()`
  相容性函式），`RunSession` 加 `analysis_runs` relationship，完全沒動既有
  `AnalysisMeta`/`analysis` relationship 與欄位。
- 新表不需要手動 migration，`db/init_db.py` 既有的 `create_all` 下次啟動自動建表；
  **沒有對 production `running.db` 做任何寫入或 schema 變更**。
- 新增 `tests/test_analysis_run_model.py`（5 tests），沿用既有 in-memory sqlite 測試慣例。
  `PYTHONPATH=. pytest -q`（`yolo_new` 環境）**19 passed**（14 既有 + 5 新增）。

## Step 10 — Backend Local ingestion 與 Compare 保存

狀態：**已完成**。記錄日期：2026-10-04。`repo: running-analysis-backend`。

- 新增 `routes/analysis_run.py`（5 條路由）、`db_models/comparison_report.py`、
  `utils/contract_v1.py`（對 `runner-analysis-pipeline` 的 canonical JSON Schema 驗證，
  不複製一份）。
- 發現並解決 Step 9 遺留的設計衝突：`AnalysisMeta` 1:1 綁 `run_session_id`，跟 Compare
  模式「一個 RunSession 兩筆 AnalysisRun」結構衝突。解法：`AnalysisRun` 加
  `result_summary` JSON 欄位自己保管結果，`AnalysisMeta` 只在非 Compare 情境同步，
  避免互相覆寫。
- 新增 `tests/test_analysis_run_ingestion.py`（6 tests）。`PYTHONPATH=. pytest -q`
  （`yolo_new` 環境）**25 passed**（19 既有 + 6 新增）。`main.py` 確認可正常 import，
  5 條新路由正確掛載。
- ingestion 刻意不呼叫 `runner-analysis-pipeline`；`ComparisonReport` 的數值差異計算
  刻意沒做（需要 Local 真的有 2D/3D 輸出才能比對），這一步只做 schema-valid 的儲存／
  查詢 plumbing。

## Step 11 — Flutter 分析 seam 與三種模式

狀態：**已完成**。記錄日期：2026-10-04。`repo: running-analysis-frontend`。

- 新增 `lib/feature/analysis/`：`analysis_mode.dart`、`analysis_request.dart`、
  `analysis_event.dart`、`analysis_executor.dart`、`server_analysis_adapter.dart`
  （真的包裝 `BackendInterface`，非假資料）、`local_analysis_adapter.dart`
  （誠實 stub，立即回報 failed，不是測試假物件）、`analysis_run_controller.dart`
  （`StateNotifier`，三種模式共用同一個 controller，取代文件原寫的獨立
  `CompareAnalysisCoordinator` class）。
- 新增 `test/analysis_run_controller_test.dart`（8 tests，用 `FakeAnalysisExecutor`
  驗證狀態機，刻意不用必敗的真實 `LocalAnalysisAdapter`）。
- `flutter analyze`：0 issues。`flutter test --concurrency=1`：**28 passed**（8 既有
  檔案全過，新增 1 個檔案 8 個測試）。預設平行跑測試時，多檔案 output 會在這個
  sandbox 的終端機 pipe 裡交錯/遺失（不是測試真的沒執行），用
  `--concurrency=1` 才能拿到可信的完整結果——往後在這個環境驗證 Flutter 測試
  都建議加這個旗標。
