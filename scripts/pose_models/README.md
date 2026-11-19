# 換 2D 骨架模型的工具

> 2026-11-19 建立

## 用途

手機端的 2D 模型以後可能從 HRNet 換成別的模型，例如 RTMPose（SimCC 類）。為了讓換模型時不必改 pipeline，每個模型用一份 **pose model spec**（JSON 描述檔）說明：

- 輸入大小與色彩；
- 輸出型態（heatmap 或 SimCC）；
- 關節怎麼對應到 WholeBody23；
- Core ML 套件的名稱。

這份格式的**正本在伺服器 repo**：`runner-analysis-pipeline/core/pose_models/`，說明文件是那邊的 `docs/developer/pose_model_spec.md`。手機端讀同一種 JSON（`Sources/RunnerPoseKit/PoseModel/PoseModelSpec.swift`），這個資料夾則是兩邊之間的工具。

## 檔案

| 檔案 | 用途 | 在 Linux 上能跑嗎 |
|---|---|---|
| `pipeline_specs.py` | 依檔案路徑載入 pipeline 的 `spec.py`、`simcc.py`，不需要整個伺服器環境。pipeline 的位置由 `$RUNNER_ANALYSIS_PIPELINE_ROOT` 指定，沒設定時用相鄰的 `../runner-analysis-pipeline` | 可以 |
| `sync_pose_specs.py` | 把 pipeline 裡手機能跑的描述檔（有 `coreml` 區段、而且不是 template）複製到 `Sources/RunnerPoseKit/Resources/PoseModels/`；`--check` 只檢查有沒有同步 | 可以 |
| `make_simcc_fixture.py` | 用 pipeline 的參考解碼器產生 `Tests/RunnerPoseKitTests/Fixtures/simcc/simcc_decode_cases.json`，供 `SimCCDecoderTests` 比對 Swift 解碼器 | 可以 |
| `convert_rtmpose_to_coreml.py` | 把 SimCC 模型（TorchScript）轉成 Core ML，並產生描述檔和轉檔報告；`--self-test` 用一個小型隨機模型檢查轉檔流程本身 | 可以轉檔；Core ML 推論比對只能在 macOS 上跑 |

2026-11-19 在 Linux 上驗證過：

- `--self-test` 產出的 `.mlpackage`：輸入是 `person_crop`（RGB 192×256），輸出是 `simcc_x` [1,23,384] 和 `simcc_y` [1,23,512]，描述檔通過 pipeline 的驗證；
- fixture 的期望值和另外重寫的 Swift 解碼規則逐值一致；
- `sync_pose_specs.py --check` 通過。

Swift 端（`PoseModel/` 和兩個測試檔）**還沒在 Mac 上編譯**，見最後一節。

## 加一個 RTMPose 模型的步驟

1. **在 MMPose 環境匯出 TorchScript。** 模型要輸入「已正規化的 float crop」，輸出 `(simcc_x, simcc_y)`。下面是 MMPose 1.x 的寫法，**沒有在這台機器上驗證過**，請依你的 MMPose 版本調整：

   ```python
   import torch
   from mmpose.apis import init_model

   model = init_model(CONFIG, CHECKPOINT, device="cpu").eval()

   class SimCCOnly(torch.nn.Module):
       def __init__(self, m):
           super().__init__()
           self.m = m

       def forward(self, x):
           return self.m.head.forward(self.m.extract_feat(x))  # (simcc_x, simcc_y)

   W, H = 192, 256  # 照 config 的 input_size
   torch.jit.trace(SimCCOnly(model), torch.randn(1, 3, H, W)).save("rtmpose.torchscript.pt")
   ```

2. **轉成 Core ML**（`torch` 和 `coremltools` 9 在 `yolo_new` 環境裡都有）：

   ```bash
   python scripts/pose_models/convert_rtmpose_to_coreml.py \
       --torchscript rtmpose.torchscript.pt --id rtmpose_m_wholebody \
       --input-size 192 256 --split-ratio 2.0 --out-dir build/pose_models
   ```

   mean/std 會包進模型裡，所以 App 只要送 0～255 的影像。在 Mac 上執行時，還會比對 Core ML 和 PyTorch 的輸出。
3. **把描述檔放進 pipeline。** 產生的 `rtmpose_m_wholebody.json` 複製到 `runner-analysis-pipeline/core/pose_models/specs/`，那邊是正本。接著在 pipeline repo 跑 `pytest tests/test_pose_models.py`。
4. **同步到手機：** 執行 `python scripts/pose_models/sync_pose_specs.py`，再把 `.mlpackage` 放進 `Sources/RunnerPoseKit/Resources/`。
5. **評估：**
   - 用新模型跑一部影片，拿手機輸出的 `keypoints_2d.json` 跟伺服器 HRNet 的 `pose/keypoints_2d.json` 比較：

     ```bash
     # 在 runner-analysis-pipeline repo
     python -m scripts.eval.pose_model_compare <伺服器的 keypoints_2d.json> <手機的 keypoints_2d.json>
     ```

   - 驗收門檻：平均誤差 < 2 px、PCK@0.05 > 0.95；
   - 通過後，再看跳遠事件和判定有沒有改變。

## 手機端的介面

| 型別 | 檔案 | 做什麼 |
|---|---|---|
| `PoseModelSpec` | `PoseModel/PoseModelSpec.swift` | 讀取和驗證描述檔；`canonicalIndices`、`missingJoints`；`require(_:for:)` 用來檢查跳遠需要的腳部關節 |
| `PoseEstimator`（protocol） | `PoseModel/PoseEstimator.swift` | 輸入 crop，輸出 `PoseModelOutput`（`.heatmap` 或 `.simcc`）。`HRNetRunner` 已經實作（`HRNetRunner+PoseEstimator.swift`） |
| `KeypointDecoder`（protocol） | `PoseModel/KeypointDecoders.swift` | `DarkHeatmapKeypointDecoder` 包住現有的 `HeatmapDecoder`；`SimCCKeypointDecoder` 是新的 |
| `CanonicalJoints.map` | `PoseModel/PoseEstimator.swift` | 原生關節轉成標準 23 點；模型沒有的關節填 NaN、分數 0 |
| `PoseModelCatalog` | `PoseModel/PoseModelCatalog.swift` | 找出 App 內附的描述檔，並依描述檔建立對應的解碼器 |

## 還沒做、要在 Mac 上完成的（TODO(mac)）

1. **編譯和測試：** `swift build`、`swift test`，新的測試是 `PoseModelSpecTests`、`SimCCDecoderTests`。這些 Swift 是在 Linux 上寫的，沒有編譯過。
2. **接上 pipeline：** `RunnerPoseEngine`／`PosePipeline` 目前還是直接建立 `HRNetRunner` 和 `HeatmapDecoder`。要改成依描述檔：`PoseModelCatalog.runnableSpec` → estimator 加 decoder → `CanonicalJoints.map`；`CropWarp` 的尺寸也改成讀 `spec.input`。這一步刻意延後，因為 `PosePipeline.swift`、`HeatmapDecoder.swift` 還有 2026-10-20 尚未 commit 的修改，等那些先 commit，兩邊才不會衝突。
3. **通用的 Core ML 執行器：** 一個只靠描述檔（輸入和輸出名稱）就能跑任何 SimCC 或 heatmap 模型的 `PoseEstimator`。HRNet 目前用的是自己的 `HRNetRunner`。
4. **確認 crop 幾何：** RTMPose 訓練時，人框是依「輸入的長寬比」補齊，並放大 1.25 倍。手機的 `Geometry.boxToCenterScale` 沿用了 HRNet 的寫法（open issues 裡的 aspect ratio quirk）。換成 RTMPose 前，要先確認裁切方式跟訓練時一致，否則關節會有系統性偏移。
5. **Flutter 外掛：** `PoseModelCatalog` 用的是 `Bundle.module`，從 Flutter 外掛使用時，資源可能在別的 bundle 裡，要比照 `ModelResources.locate` 的搜尋方式。
