# 本次 session 異動總覽（2026-10-04）

記錄這次對話裡我實際動過的檔案，依 repo 分類。每個 repo 目前 `git status` 顯示的
dirty 檔案不只這些——其他未列出的檔案是其他 session／使用者自己的工作，不是我動的，
已在下方各 repo 小節的「不是我動的」特別註明，避免跟你自己的進度搞混。

## 1. `runner-pose-ondevice`

### 文件
- **`GitHub 上傳操作指南.md`**：新增「更新到指定 commit 版本」（`git fetch` +
  `merge --ff-only`／`checkout FETCH_HEAD`）與「確認本機目前的版本」
  （`git rev-parse HEAD`、`git log -1 --oneline` 等）兩個章節。
- **`report/integration_guide.md`**：從 v2（手機只做 2D、server 做下游）整個改寫成
  v3（Server/Local/Compare 三模式整合計畫），並在對話過程中持續更新 Step 0–11 的
  完成狀態、審查發現與修正記錄。這是這次改動最多的檔案。
- **`docs/PLAN.md`/ `docs/plan.html`**：同步 v2 的架構修正（§11/§12），記錄
  `offsets_npz`、多相機假設、23-joint schema 注入點等風險，並把「整合方向確認」
  標記為已確認。
- **`report/local_pipeline_execution_log.md`**（新檔）：逐 Step 記錄實際執行結果
  （Linux baseline、Mac build 狀態、Step 2–11 的審查/實作/測試結果）。
- **`report/motionagformer_coreml_spike.md`**（新檔）：MotionAGFormer → Core ML
  可行性 spike 的完整報告（結論 GO、rank-6 reshape 修正、NumPy 2.x 相容性 bug）。

### 程式碼
- **`scripts/motionagformer_coreml_spike.py`**（新檔）：轉換腳本本身，含
  rank-6 reshape 的驗證修正與 NumPy 2.x cast bug 的 monkeypatch。
- **`report/motionagformer_coreml/`**（新目錄，執行產物）：`large_h36m/`、
  `small_ap3d/` 兩個變體的 `.mlpackage`、PyTorch 參考輸入／輸出 `.npy`、
  `spike_result.json`。

### 不是我動的
`BenchApp/BenchApp/ContentView.swift`、`BenchApp/README.md`、
`Sources/RunnerPoseKit/Bench/{BenchReport,Samplers}.swift`、
`Sources/RunnerPoseKit/Pipeline/PosePipeline.swift`、
`Sources/RunnerPoseKit/RunnerPoseEngine.swift`、
`Tests/RunnerPoseKitTests/OutputSchemaTests.swift`——這是 Mac 那個 session 做的
BenchReport power/hardwareIdentifier 改動，我只有審查過（確認邏輯正確），沒有修改。
三個 `*.json` 和 `IMG_0085(1).MOV` 是你提供的 BenchReport 實機數據檔案。

## 2. `runner-analysis-pipeline`

- **`core/pipeline/final_export.py`**：新增 `run_analysis_with_manifest()`，包在
  `run_analysis()` 外層，呼叫後額外產生 `manifest.json`，**沒有修改
  `run_analysis()` 本身**。
- **`core/pipeline/__init__.py`**：把 `run_analysis_with_manifest` 加進
  re-export 清單。
- **`analyze.py`**：demo `__main__` 改用 `run_analysis_with_manifest()`，帶上
  YOLO／HRNet／MotionAGFormer 的真實模型路徑。
- **`tests/contracts/test_run_analysis_with_manifest.py`**（新檔）：2 個測試，
  monkeypatch 掉 `run_analysis` 驗證 wrapper 不改變行為、manifest 寫到正確目錄。

### 不是我動的
`contracts/analysis/v1/`、`core/contracts/`、`MotionAGFormer/demo/{vis.py,lib/preprocess.py}`、
`core/pipeline/{orchestration,pose_step,tracking_step}.py`、`core/pose_stream.py`、
`docs/experiments/`、以及其餘上百個 dirty 檔案——這些是另一個並行 session 做的
canonical contract／golden corpus 工作，跟你自己測試用的 MogaNet/AP3D 模型替換。
我只有審查（用 agent 做過一次對抗性審查，詳見 `integration_guide.md` Step 2–4
段落），**沒有修改**任何一個檔案。

## 3. `running-analysis-backend`（`running-analysis-backend/running-analysis-backend`）

### 新增檔案
- `db_models/analysis_run.py`：`AnalysisRun` 表 + `synthesize_legacy_server_run()`。
- `db_models/comparison_report.py`：`ComparisonReport` 表。
- `utils/contract_v1.py`：對 `runner-analysis-pipeline` 的 canonical JSON Schema
  做驗證，不複製一份 schema。
- `routes/analysis_run.py`：5 條新路由（建立 Local run、上傳 manifest、查詢 run、
  送出/查詢 ComparisonReport）。
- `tests/test_analysis_run_model.py`（5 tests）、
  `tests/test_analysis_run_ingestion.py`（6 tests）。

### 修改既有檔案
- `db_models/__init__.py`：匯出 `AnalysisRun`、`ComparisonReport`、
  `synthesize_legacy_server_run`。
- `db_models/run_session.py`：加 `analysis_runs: List["AnalysisRun"]`
  relationship，**沒有動**既有 `analysis`/`AnalysisMeta` 欄位。
- `main.py`：掛載 `analysis_run_router`。
- `response_chemas.py`：加 `CreateLocalAnalysisRunIn/Out`、`AnalysisRunOut`。

結果：`PYTHONPATH=. pytest -q`（`yolo_new` 環境）**25 passed**（19 既有 + 6 新增，
其中 5 個是 `AnalysisRun` model 本身的測試、6 個是 ingestion 流程的測試——兩份
test 檔加起來 11 個新測試，既有 14 個全過）。**沒有對正式的 `running.db` 做任何
寫入或 schema 變更**；新表等下次正常啟動 app 時由既有的 `create_all` 自動建立。

### 不是我動的
`analyze.py`、`config.py`、`db/init_db.py`、`db_models/user.py`、
`routes/{auth,run,trial_review,upload}.py`、
`tests/{test_database_migrations,test_upload_anchor_contract,test_cleanup,test_collaborative_upload_contract,test_trial_review_camera_alignment}.py`、
`utils/cleanup.py`——這些在我開始這次工作前就已經是 dirty 狀態（Step 0 基準記錄時
就記錄了「12 tracked changes、4 untracked」），是你自己原本在做的工作。

## 4. `running-analysis-frontend`（`running-analysis-frontend/running-analysis-frontend`）

### 新增檔案
- `lib/feature/analysis/`（新目錄，7 個檔案）：
  `analysis_mode.dart`、`analysis_request.dart`、`analysis_event.dart`、
  `analysis_executor.dart`、`server_analysis_adapter.dart`（真的包裝
  `BackendInterface`）、`local_analysis_adapter.dart`（誠實的「尚未支援」stub，
  不是測試假物件）、`analysis_run_controller.dart`（三種模式共用的
  `StateNotifier` 狀態機）。
- `test/analysis_run_controller_test.dart`（8 tests，用 `FakeAnalysisExecutor`
  驗證狀態機）。

結果：`flutter analyze` 0 issues；`flutter test --concurrency=1` **28 passed**
（8 個既有測試檔案全過 + 新增 1 個檔案 8 個測試）。

> 這個環境下 `flutter test` 預設平行跑測試時，多檔案的終端機 output 會在
> sandbox 的 pipe 裡交錯/遺失（不是測試真的沒執行），之後要在這裡驗證 Flutter
> 測試都建議加 `--concurrency=1` 才能拿到可信的完整結果。

### 不是我動的
`COMPARISON_d760f61_vs_f413c3c.md`、`FIX_LIST_integrate_f413c3c.md`、
`FIX_PLAN_sync_upload_stuck.md`、`MISSING_FEATURES_FROM_f413c3c.md`、`tatus`——
這些在這次工作前就已經是未追蹤檔案（Step 0 基準記錄「5 untracked」），不是我建立的。

## 整體結論

這四個 repo 裡，目前**唯一還沒動工、且必須在 Mac + Xcode + iPhone 上才能繼續**的
是 `runner-pose-ondevice` 的 Step 6–8（`RunnerAnalysisKit` Swift 外殼）與之後
依賴它的 Step 12–19——這台 Linux 機器完全沒有 Swift 工具鏈，無法編譯驗證，
刻意沒有動手寫任何新 Swift 程式碼。詳細待辦與每個 Step 的完成條件都在
`report/integration_guide.md` 裡。
