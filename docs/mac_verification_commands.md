# Mac / iPad 驗證指令

runner-pose-ondevice 分支：`feat/manifest-model-provenance`（需包含 commit `048cbc0`）
前端分支：`integrate/f413c3c`（commit `c2b04c5`）
Backend：`http://catslab.ee.ncku.edu.tw:18000/running_analysis/api`
iPad：`00008122-001910622279801C`

任何一步出現 error 就停止，把該指令開始的完整輸出貼給 Claude。

---

## 1. 取得新分支

```bash
cd /Users/catslab/dev/runner-pose-ondevice
git status -sb
git fetch origin
git switch feat/manifest-model-provenance
git pull
git log --oneline -8
```

預期：輸出中有 `048cbc0 feat: add local contact and gait analysis`、
`f65b5b9 refactor: balance temporal pose crop coverage` 與
`983e9d3 fix: detect runner on every local frame`。
`?? BenchApp/.build-spm/` 是編譯暫存，可忽略。

## 2. Swift 測試

```bash
cd /Users/catslab/dev/runner-pose-ondevice
swift test --filter RunnerAnalysisKitTests
swift test --filter RunnerPoseKitTests
```

預期：兩個都顯示 `Executed N tests, with 0 failures`。

## 2A. BenchApp 比較 YOLO26L／YOLO26X（模型補測時執行）

這一節只測原生 BenchApp 的 detector 準確度與效能，不會啟動 Flutter Local／Compare 流程。

```bash
cd /Users/catslab/dev/runner-pose-ondevice
scripts/fetch_models.sh --scales l x

test -f Sources/RunnerPoseKit/Resources/yolo26l.mlpackage/Manifest.json
test -f Sources/RunnerPoseKit/Resources/yolo26x.mlpackage/Manifest.json

xcodebuild \
  -project BenchApp/BenchApp.xcodeproj \
  -scheme BenchApp \
  -configuration Release \
  -destination 'platform=iOS,id=00008122-001910622279801C' \
  -derivedDataPath BenchApp/.build-spm \
  -allowProvisioningUpdates \
  build

open BenchApp/BenchApp.xcodeproj
```

在 Xcode 選同一台 iPad 後執行 `Product > Run`。BenchApp 使用同一支影片，先以以下設定各跑
`yolo26l`、`yolo26x` 三次：

- Compute：`cpuAndNeuralEngine`
- Detector cadence：`1`
- Max in flight：`3`
- Warmup runs：`3`
- Variant：`naive`

比較 `effective FPS`、`detect mean/p90`、`peak memory`、thermal，以及匯出的 prescan／YOLO bbox
影片是否仍有跑者漏檢。若 `yolo26x` 較準但 cadence 1 低於 15 FPS，再測 cadence 3 與 6。

正式預設仍是 `yolo26l`；本節不會把 Flutter Local 正式模型切換成 `yolo26x`。

## 3. 更新前端（pull + dependencies + Pods）

```bash
cd /Users/catslab/dev/running-analysis-frontend/running-analysis-frontend
git status -sb
git pull --rebase --autostash origin integrate/f413c3c
git log --oneline -3
flutter pub get
cd ios
pod install
cd ..
```

預期：`git log` 有 `c2b04c5 feat: show anchor dialog for Local videos ...`，本機 commit `eeed602` 仍在最上面；
`Got dependencies!`、`Pod installation complete!`。
`--autostash` 會暫存 6 個本機修改、pull 後自動放回。若出現 `CONFLICT`，停止並貼輸出。

## 4. 前端檢查

```bash
cd /Users/catslab/dev/running-analysis-frontend/running-analysis-frontend
flutter analyze
flutter test --concurrency=1
```

預期：analyze 只有 info、沒有 error；test 顯示 `All tests passed!`。

## 5. 安裝並啟動 App（Local 模式）

```bash
cd /Users/catslab/dev/running-analysis-frontend/running-analysis-frontend
flutter devices
flutter run \
  -d 00008122-001910622279801C \
  --debug \
  --dart-define=ENABLE_LOCAL_ANALYSIS=true \
  --dart-define=ENABLE_COMPARE_ANALYSIS=false \
  --dart-define=API_BASE_URL=http://catslab.ee.ncku.edu.tw:18000/running_analysis/api
```

預期：`Installing and launching...` 與 `Flutter run key commands.`。Terminal 保持開啟。

## 6. App 內操作（Local）

1. 登入（backend 重啟後需重新登入）。
2. 上傳 → Upload All → **Local** → 相機 1。
3. 選 `IMG_0247.MOV`，選完會自動跳出錨點頁（背景是影片第一幀）。
4. **點好錨點並輸入距離**後確認（若跳過，可點縮圖右上角的錨點標籤重新設定；沒有錨點，速度階段會被跳過）。
5. 開始分析，等待自動進入結果頁。
6. 確認影片可回放、角度、速度、步幅與步頻圖表有資料。
7. 檢查 Local overlay：起跑前只保留最多五幀 pre-roll，連續三幀向終點前進後才開始；通過終點線
   的該幀仍會輸出，之後不再出現 bbox／骨架。
8. 檢查骨架顏色：左側身體線藍色、右側身體線紅色、身體關節綠色、左腳黃色、右腳洋紅色。

完成後告訴 Claude「跑完了」。Claude 會在 backend 檢查：
- `engine.models` 有 `yolo26l`、`HRNetRunnerWholeBody23`、`MotionAGFormerLarge243` 與 sha256
- `runner_pose_bench.json` 的 `detectorCadence` 為 `1`、`extrapolatedFrames` 為 `0`
- bundle 與後端都有 `diagnostics/resource_trace.json`、`diagnostics/runner_pose_frames.csv`
- `resource_trace.json` 至少包含 `pose2d`、`pose3d`、`speed`、`gait`、`export`，並可讀到 `peak_mb`
- speed stage 為 `completed`，`metrics.json` 速度合理
- gait stage 為 `completed`，bundle 有 `gait/leg_identity.json`、`gait/contacts.json`、`gait/steps.json`
- `summary.detected_steps` 大於 0，`average_cadence_spm` 與 `average_step_length_m` 合理

## 7. Compare（Local 驗證通過後）

在 `flutter run` 的 Terminal 按 `q` 結束，再執行：

```bash
cd /Users/catslab/dev/running-analysis-frontend/running-analysis-frontend
flutter run \
  -d 00008122-001910622279801C \
  --debug \
  --dart-define=ENABLE_LOCAL_ANALYSIS=true \
  --dart-define=ENABLE_COMPARE_ANALYSIS=true \
  --dart-define=API_BASE_URL=http://catslab.ee.ncku.edu.tw:18000/running_analysis/api
```

App 內：上傳 → Upload All → **Compare** → 相機 1 → 同一部 `IMG_0247.MOV` → 與第 6 步相同的 FPS、錨點、距離 → 開始分析 → 等 Server 與 Local 都完成 → 查看比較結果頁。

完成後告訴 Claude「Compare 跑完了」，不需要抄 ID。

ComparisonReport 預期同時包含：

- 2D WholeBody23／foot6 pixel delta
- 3D joint frame match、MAE 與 P95
- angle frame match、MAE 與 P95
- distance／speed／acceleration MAE

第一次同輸入真機 Compare 前，3D 與角度 tolerance 會在報告 warnings 中標記為 provisional；
這次量測結果用來決定正式門檻。

---

## 常見狀況

| 狀況 | 處理 |
|---|---|
| `Could not find a command named "devices~"` | 指令多打了字元，重新輸入 `flutter devices` |
| 登入失敗 | 告訴 Claude，檢查 backend 18000 是否在運作 |
| `Lost connection to device` / 分析卡住 | 不要重試多次，貼上 Terminal 完整輸出 |
| CocoaPods duplicate UUID warning | 只是 warning，不影響 build |
| Swift Package Manager 不支援 `runner_pose` 的提醒 | 未來相容性提醒，不影響 build |
