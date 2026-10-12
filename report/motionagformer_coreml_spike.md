# MotionAGFormer → Core ML 可行性 spike（規劃書 §13 Step 5）

記錄日期：2026-10-04（Linux host，無 Mac/iPhone）
腳本：`scripts/motionagformer_coreml_spike.py`
產物：`report/motionagformer_coreml/{large_h36m,small_ap3d}/`（`model.mlpackage`、
`reference_output.npy`、`example_input.npy`、`spike_result.json`）

## 結論：GO

官方正式路徑（`MotionAGFormer-large.yaml` + `motionagformer-l-h36m.pth.tr`，
`n_frames=243`，git 乾淨 HEAD 上 `vis.py` 用的組合）**可以轉換成 Core ML**，但需要
一個已驗證、零數值誤差的小修正（見下方「發現 1」）。使用者目前自己測試用的
`small/ap3d`（`n_frames=81`）組合也用同一套修正成功轉換，確認問題不是 n_frames
相依。

## Sequence window：81 vs 243（規劃書要求驗證項目）

`n_frames` 是在建構模型時就烘進 graph 結構的靜態參數（例如
`MotionAGFormer/model/MotionAGFormer.py` 的 temporal GCN 層用
`num_nodes=n_frames` 建圖），**不是** runtime 可變的 dynamic shape。這代表：

- Core ML 端無法用同一個模型檔案同時吃 81 幀與 243 幀的 clip；兩種 `n_frames`
  需要**各自匯出一個固定輸入 shape 的 .mlpackage**。
- 官方正式路徑固定是 243（`MotionAGFormer-large.yaml`）。Local pipeline 若要
  跟 Server 功能一致，應該匯出 243-frame 版本；81-frame（small/ap3d）版本這次
  只是順便驗證同一個修正是否也適用，不代表要在 Local 用這個變體。

## 發現 1（CRITICAL，已驗證修正）：coremltools 9.0 無法處理 QKV 合併 reshape

**現象**：`torch.jit.trace` 成功，但 `coremltools.convert()` 在驗證階段報錯：

```
ValueError: Core ML only supports tensors with rank <= 5. Layer "op_115_cast_fp16",
with type "reshape", outputs a rank 6 tensor.
```

**根因**：`MotionAGFormer/model/modules/attention.py:26`（`Attention.forward`）與
`ctr_attention.py:75-76`（`CTRAttention.forward`）都用同一個 pattern，把合併的
QKV 投影一次性 reshape 成 6 維：

```python
qkv = self.qkv(x).reshape(B, T, J, 3, self.num_heads, head_dim).permute(3, 0, 4, 1, 2, 5)
```

Core ML 的 MIL 只允許 rank ≤ 5 的 tensor，這個 reshape 直接超標，跟 `n_frames`
無關、每一層的每一個 attention 模組都會觸發（large 模型共 52 個 Attention/
CTRAttention 實例，全部中標）。

**修正**（只存在於 `scripts/motionagformer_coreml_spike.py`，**沒有修改
`runner-analysis-pipeline` 的任何檔案**，現有 Python 推論路徑與已訓練 checkpoint
完全不受影響）：把同一個 reshape 拆成兩步，避免中途出現 6 維張量——先把
`(3, num_heads, head_dim)` 合併reshape 成一個 5 維的 `(3*num_heads, head_dim)`，
再用**切片**（不是另一次 reshape）取出 q/k/v 三段：

```python
qkv = self.qkv(x).reshape(B, T, J, 3 * self.num_heads, head_dim)
q = qkv[:, :, :, 0:num_heads, :].permute(0, 3, 1, 2, 4)
k = qkv[:, :, :, num_heads:2*num_heads, :].permute(0, 3, 1, 2, 4)
v = qkv[:, :, :, 2*num_heads:3*num_heads, :].permute(0, 3, 1, 2, 4)
```

這在數學上跟原本的寫法完全等價（row-major reshape 下 `merged_idx = three_idx *
num_heads + head_idx`，切片精確對應原本三段），不是近似。**已用程式驗證**：
patch 前後用同一組隨機輸入跑完整模型，`max_abs_delta = 0.0`（bit-identical），
不是靠肉眼檢查或猜測正確性。

**後續動作建議**：這個修正應該要變成 `runner-analysis-pipeline` 裡
`attention.py`/`ctr_attention.py` 的正式程式碼（對現有 Python 推論路徑無副作用，
純粹是 reshape 分解），而不是永遠留在 export-only 腳本裡用 monkeypatch 繞過——
這樣以後 Server 端重新匯出 Core ML 版本時不用每次重新套用 patch。**這次 spike
刻意沒有動 `runner-analysis-pipeline` 的檔案**，因為這已經超出「驗證可行性」的
範圍，牽涉到production 程式碼變更，應該另外決定要不要做、誰來做。

## 發現 2：無法在 Linux 驗證數值正確性

`mlmodel.predict(...)` 在這台 Linux host 上直接丟出
`Exception: Model prediction is only supported on macOS version 10.13 or later.`
——這是 Core ML runtime 本身的限制，不是轉換失敗，預期之中。**轉換成功
不等於推論結果正確**；PyTorch 參考輸出（`reference_output.npy`）與輸入
（`example_input.npy`）已經存好，下一步需要在 Mac 上跑同一組輸入，比對
Core ML 輸出跟這份參考輸出的誤差，才能確認數值 parity。

## 其他數據

| 項目 | large_h36m（n_frames=243，官方） | small_ap3d（n_frames=81，使用者測試用） |
|---|---|---|
| trace | 成功 | 成功 |
| convert（套用修正後） | 成功 | 成功 |
| .mlpackage 大小 | 38 MB | 11 MB |
| 修正前後數值誤差 | 0.0（bit-identical） | 0.0（bit-identical） |
| minimum_deployment_target | iOS 16 | iOS 16 |
| compute_units | ALL（CPU+GPU+ANE，實際分配由裝置決定） | 同左 |

38 MB（fp16，large/243）遠小於 HRNet fp16（~120 MB），對 §11 風險表「模型總大小
過大」是好消息，但仍要加總 YOLO + HRNet + MotionAGFormer 三個模型一起估 App
bundle／版本化下載的總體積。

## 額外發現：`int()` cast 的 NumPy 2.x 相容性問題（非阻塞，已繞過）

套用上面的 reshape 修正前，第一次嘗試轉換時卡在更早的一步：

```
TypeError: only 0-dimensional arrays can be converted to Python scalars
```

根因是 `coremltools` 9.0（PyPI 上最新版）的 `ops.py::_cast()` 對編譯期常數做
`dtype(x.val)`，當 `x.val` 是 shape `(1,)`、ndim=1 的 numpy 陣列時，NumPy ≥ 2.0
已經移除了這種陣列到 Python scalar 的隱式轉換（`int(np.array([5]))` 在 NumPy
2.4.6 上直接拋例外，`int(np.array(5))` 真正 0 維的才可以）。已用同一台機器的
`python -c` 重現兩種情況的行為差異確認根因，不是憑空猜測。這台機器的
`yolo_new` conda 環境是 NumPy 2.4.6。

**處理方式**：沒有改動共用的 `yolo_new` 環境（避免影響該環境給其他工作用的
NumPy 版本），而是在 spike 腳本裡對 `coremltools.converters.mil.frontend.torch.ops._cast`
做一個小 monkeypatch，把 `dtype(x.val)` 改成先 `np.asarray(x.val).reshape(-1)[0]`
再轉型。這只影響這支 spike 腳本的 process，不影響其他使用 coremltools/NumPy 的
程式碼。

**對 Local pipeline 工作的意義**：之後任何人要在這個 repo 或 Mac 上用
coremltools 9.0 轉換涉及 shape-derived int cast 的模型（不只 MotionAGFormer），
都可能撞到同一個問題。如果 Mac 上的 coremltools 版本不同、或 NumPy 版本 < 2.0，
可能根本不會出現——動工前應該先確認 Mac 端實際的 coremltools + NumPy 版本組合，
不要預設一定要套用這個 patch。

## 對規劃書其他項目的影響

- §11 風險表「MotionAGFormer 無法直接穩定轉 Core ML」：**風險已降低但未歸零**——
  轉換本身可行，前提是先把 attention reshape 修正真正落地到
  `runner-analysis-pipeline`（或在 Local 端的轉換腳本裡長期維護這個 patch）。
  數值 parity 仍待 Mac 驗證。
- Step 17（3D 與角度正式整合）的前置條件現在明確：先決定 attention reshape
  修正要落在哪個 repo、由誰驗證跟現有 checkpoint 100% 相容，再開始包裝成
  Swift 3D runner。
