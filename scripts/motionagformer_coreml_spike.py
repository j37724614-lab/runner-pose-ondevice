#!/usr/bin/env python3
"""Step 5 可行性 spike：MotionAGFormer -> Core ML（規劃書 report/integration_guide.md §13）。

這支腳本只做轉換可行性驗證，不是正式產品程式碼：

1. 用官方 checkpoint（motionagformer-l-h36m.pth.tr，n_frames=243）載入 PyTorch 模型。
2. 跑一次確定性的 forward pass，存下 PyTorch 參考輸出。
3. `torch.jit.trace` + `coremltools.convert` 成 .mlpackage，記錄轉換是否成功、
   有哪些 op 需要特別處理。
4. 嘗試在本機跑 Core ML 推論做數值比對——Linux 上通常沒有 Core ML runtime，
   跑不動屬於預期行為，會記錄下來，不是這支腳本的 bug。

用法：
    python scripts/motionagformer_coreml_spike.py --variant large_h36m
    python scripts/motionagformer_coreml_spike.py --variant small_ap3d

輸出：
    report/motionagformer_coreml/<variant>/model.mlpackage
    report/motionagformer_coreml/<variant>/reference_output.npy
    report/motionagformer_coreml/<variant>/spike_result.json
"""
from __future__ import annotations

import argparse
import inspect
import json
import sys
import traceback
from pathlib import Path

import numpy as np
import torch
import yaml
from torch import nn

PIPELINE_REPO = Path("/home/jeter/runner-analysis-pipeline")
MOTIONAGFORMER_ROOT = PIPELINE_REPO / "MotionAGFormer"
for path in (str(PIPELINE_REPO), str(MOTIONAGFORMER_ROOT)):
    if path not in sys.path:
        sys.path.insert(0, path)

from model.MotionAGFormer import MotionAGFormer  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_ROOT = REPO_ROOT / "report" / "motionagformer_coreml"

VARIANTS = {
    # 官方、git-committed 的正式路徑（MotionAGFormer/demo/vis.py 在乾淨 HEAD 上用的組合）。
    "large_h36m": {
        "config": MOTIONAGFORMER_ROOT / "configs" / "h36m" / "MotionAGFormer-large.yaml",
        "checkpoint": MOTIONAGFORMER_ROOT / "checkpoint" / "motionagformer-l-h36m.pth.tr",
        "n_frames": 243,
    },
    # 使用者目前自己測試用的組合（small/ap3d, n_frames=81）；僅為了同時驗證
    # 81-frame 路徑是否一樣能轉換，不代表這是正式路徑。
    "small_ap3d": {
        "config": MOTIONAGFORMER_ROOT / "configs" / "h36m" / "MotionAGFormer-small.yaml",
        "checkpoint": MOTIONAGFORMER_ROOT / "checkpoint" / "motionagformer-s-ap3d.pth.tr",
        "n_frames": 81,
    },
}


def _load_config(config_path: Path) -> dict:
    with open(config_path) as f:
        config = yaml.safe_load(f)
    if isinstance(config.get("act_layer"), str):
        config["act_layer"] = {"gelu": nn.GELU, "relu": nn.ReLU}[config["act_layer"].lower()]
    for key, value in list(config.items()):
        if isinstance(value, str) and value.lower() in ("true", "false"):
            config[key] = value.lower() == "true"
    model_keys = set(inspect.signature(MotionAGFormer.__init__).parameters.keys()) - {"self"}
    return {k: v for k, v in config.items() if k in model_keys}


def _load_model(variant: dict) -> MotionAGFormer:
    model_config = _load_config(variant["config"])
    model = MotionAGFormer(**model_config)
    checkpoint = torch.load(variant["checkpoint"], map_location="cpu", weights_only=False)
    # Checkpoint was saved from an `nn.DataParallel`-wrapped model, so keys are
    # prefixed with "module.". DataParallel itself is not meaningful/convertible
    # for a single-host export, and on a CUDA-visible host it silently replicates
    # onto the GPU even without an explicit .cuda() call - so we load straight
    # into the unwrapped module and keep everything on CPU.
    state_dict = {
        key.removeprefix("module."): value for key, value in checkpoint["model"].items()
    }
    model.load_state_dict(state_dict, strict=True)
    model.eval()
    return model


def _patch_coremltools_numpy2_cast_bug() -> None:
    """coremltools 9.0 (latest on PyPI as of this spike) ops.py `_cast()` does
    `dtype(x.val)` to fold a compile-time-constant scalar/length-1 tensor into
    an `int`/`bool`. Under NumPy < 2.0, `int(np.array([5]))` (shape (1,), ndim
    1) implicitly coerced to a Python scalar; NumPy 2.0 removed that coercion
    for any array with ndim > 0, so this now raises
    `TypeError: only 0-dimensional arrays can be converted to Python scalars`
    for every traced MotionAGFormer attention/graph block that casts a
    shape-derived length-1 tensor to int (e.g. `0/att_spatial/mixer/...`).
    This is a coremltools/NumPy-2.x compatibility bug, not a MotionAGFormer
    architecture blocker - verified by reproducing `int(np.array([5]))`
    failing under NumPy 2.4.6 while `int(np.array(5))` (true 0-d) succeeds.
    Patched here instead of pinning NumPy <2 in the shared conda env, to avoid
    touching dependencies other work in that environment relies on.
    """
    import numpy as np
    from coremltools.converters.mil.frontend.torch import ops as torch_ops

    mb = torch_ops.mb

    def _patched_cast(context, node, dtype, dtype_name):
        inputs = torch_ops._get_inputs(context, node, expected=1)
        x = inputs[0]
        if not (len(x.shape) == 0 or np.all([d == 1 for d in x.shape])):
            raise ValueError("input to cast must be either a scalar or a length 1 tensor")

        if x.can_be_folded_to_const():
            value = np.asarray(x.val).reshape(-1)[0] if np.ndim(x.val) > 0 else x.val
            if not isinstance(value, dtype):
                res = mb.const(val=dtype(value), name=node.name)
            else:
                res = x
        elif len(x.shape) > 0:
            x = mb.squeeze(x=x, name=node.name + "_item")
            res = mb.cast(x=x, dtype=dtype_name, name=node.name)
        else:
            res = mb.cast(x=x, dtype=dtype_name, name=node.name)
        context.add(res, node.name)

    torch_ops._cast = _patched_cast


def _rank5_attention_forward(self, x):
    """Drop-in replacement for `Attention.forward` / `CTRAttention.forward`
    (MotionAGFormer/model/modules/{attention,ctr_attention}.py) that produces
    the exact same q/k/v tensors without ever materializing a rank-6 tensor.

    The original does `self.qkv(x).reshape(B, T, J, 3, num_heads, head_dim)`
    in one step - 6 dims, which Core ML's MIL rejects (rank <= 5 only). This
    instead merges the "3" (qkv) and "num_heads" axes into one axis of size
    `3 * num_heads` (reshape stays rank 5), then **slices** that merged axis
    into three `num_heads`-wide chunks instead of indexing a separate axis.
    This is exact, not an approximation: for a row-major reshape, flattening
    `(3, num_heads, head_dim)` into `(3 * num_heads, head_dim)` preserves
    `merged_idx = three_idx * num_heads + head_idx`, so slice
    `[0:num_heads]`/`[num_heads:2*num_heads]`/`[2*num_heads:3*num_heads]`
    recovers exactly q/k/v in the original head order. Verified numerically
    against the unpatched forward before this is trusted for conversion (see
    `_verify_patched_model_matches_reference` below) - not just asserted.

    Only used inside this Core ML conversion spike; does not touch
    `runner-analysis-pipeline`'s model source, so the existing Python
    inference path (and its already-trained checkpoint, which this reuses
    unmodified) is completely unaffected.
    """
    B, T, J, C = x.shape
    # CTRAttention projects to `inter_channel * 3` instead of `dim_in * 3`;
    # derive head_dim from the actual qkv output width so both classes share
    # this one function.
    head_dim = self.qkv.out_features // (3 * self.num_heads)
    qkv = self.qkv(x).reshape(B, T, J, 3 * self.num_heads, head_dim)
    q = qkv[:, :, :, 0 : self.num_heads, :].permute(0, 3, 1, 2, 4)
    k = qkv[:, :, :, self.num_heads : 2 * self.num_heads, :].permute(0, 3, 1, 2, 4)
    v = qkv[:, :, :, 2 * self.num_heads : 3 * self.num_heads, :].permute(0, 3, 1, 2, 4)

    is_ctr_attention = hasattr(self, "inter_channel")  # only CTRAttention sets this
    if self.mode == "temporal":
        if is_ctr_attention:
            xx = None
            if self.use_self_similarity:
                x_ = x.transpose(1, 2)
                x_t = x_.transpose(2, 3)
                xx = x_ @ x_t
            x = self.forward_temporal(q, k, v, xx)
        else:
            x = self.forward_temporal(q, k, v)
    elif self.mode == "spatial":
        if is_ctr_attention:
            xx = None
            if self.use_self_similarity:
                x_t = x.transpose(2, 3)
                xx = x @ x_t
            x = self.forward_spatial(q, k, v, xx)
        else:
            x = self.forward_spatial(q, k, v)
    else:
        raise NotImplementedError(self.mode)
    x = self.proj(x)
    x = self.proj_drop(x)
    return x


def _patch_rank6_qkv_reshape(model: nn.Module) -> int:
    """Rebind `forward` on every Attention/CTRAttention instance in `model`
    to the rank-5-only version above. Returns how many modules were patched
    (0 would mean this spike's premise - that these classes exist in the
    graph - no longer holds and the result should not be trusted)."""
    import types

    patched = 0
    for module in model.modules():
        if type(module).__name__ in ("Attention", "CTRAttention"):
            module.forward = types.MethodType(_rank5_attention_forward, module)
            patched += 1
    return patched


def _verify_patched_model_matches_reference(
    model: nn.Module, example_input: torch.Tensor, reference_output: torch.Tensor
) -> float:
    with torch.no_grad():
        patched_output = model(example_input)
    max_abs_delta = (patched_output - reference_output).abs().max().item()
    return max_abs_delta


def run_spike(variant_name: str) -> dict:
    variant = VARIANTS[variant_name]
    n_frames = variant["n_frames"]
    out_dir = OUTPUT_ROOT / variant_name
    out_dir.mkdir(parents=True, exist_ok=True)

    result: dict = {
        "variant": variant_name,
        "config": str(variant["config"]),
        "checkpoint": str(variant["checkpoint"]),
        "n_frames": n_frames,
        "torch_version": torch.__version__,
    }

    model = _load_model(variant)

    # input shape per MotionAGFormer.forward docstring: [B, T, J, C] = [1, n_frames, 17, 3]
    # (x, y normalized screen coords + confidence - matches keypoints.npz 'reconstruction' shape).
    generator = torch.Generator().manual_seed(0)
    example_input = torch.randn((1, n_frames, 17, 3), generator=generator)

    with torch.no_grad():
        reference_output = model(example_input)
    np.save(out_dir / "reference_output.npy", reference_output.numpy())
    np.save(out_dir / "example_input.npy", example_input.numpy())
    result["reference_output_shape"] = list(reference_output.shape)

    # The original Attention/CTRAttention.forward does a rank-6 reshape that
    # Core ML's MIL rejects outright (see _rank5_attention_forward docstring).
    # Patch it to an exactly-equivalent rank-5-only version, in this process
    # only, and verify the full model still produces the same output before
    # trusting the patched graph for conversion.
    patched_modules = _patch_rank6_qkv_reshape(model)
    result["rank6_reshape_patch_applied_to_n_modules"] = patched_modules
    if patched_modules:
        delta = _verify_patched_model_matches_reference(model, example_input, reference_output)
        result["rank6_patch_max_abs_delta_vs_unpatched"] = delta
        if delta > 1e-4:
            result["rank6_patch_verified_equivalent"] = False
            return result
        result["rank6_patch_verified_equivalent"] = True

    try:
        traced = torch.jit.trace(model, example_input)
        result["trace_succeeded"] = True
    except Exception as error:  # noqa: BLE001
        result["trace_succeeded"] = False
        result["trace_error"] = f"{type(error).__name__}: {error}"
        result["trace_traceback"] = traceback.format_exc()
        return result

    try:
        import coremltools as ct

        _patch_coremltools_numpy2_cast_bug()
        result["coremltools_version"] = ct.__version__
        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name="pose2d_input", shape=example_input.shape)],
            outputs=[ct.TensorType(name="pose3d_output")],
            minimum_deployment_target=ct.target.iOS16,
            compute_units=ct.ComputeUnit.ALL,
            convert_to="mlprogram",
        )
        mlpackage_path = out_dir / "model.mlpackage"
        mlmodel.save(str(mlpackage_path))
        result["convert_succeeded"] = True
        result["mlpackage_path"] = str(mlpackage_path)
    except Exception as error:  # noqa: BLE001
        result["convert_succeeded"] = False
        result["convert_error"] = f"{type(error).__name__}: {error}"
        result["convert_traceback"] = traceback.format_exc()
        return result

    # Core ML prediction generally requires a macOS host with the Core ML
    # framework; this is expected to fail here and is not a spike failure.
    try:
        prediction = mlmodel.predict({"pose2d_input": example_input.numpy()})
        predicted = prediction["pose3d_output"]
        delta = np.abs(predicted - reference_output.numpy())
        result["local_predict_succeeded"] = True
        result["max_abs_delta_vs_pytorch"] = float(delta.max())
        result["mean_abs_delta_vs_pytorch"] = float(delta.mean())
    except Exception as error:  # noqa: BLE001
        result["local_predict_succeeded"] = False
        result["local_predict_error"] = f"{type(error).__name__}: {error}"

    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=sorted(VARIANTS), required=True)
    args = parser.parse_args()

    result = run_spike(args.variant)
    out_dir = OUTPUT_ROOT / args.variant
    out_dir.mkdir(parents=True, exist_ok=True)
    result_path = out_dir / "spike_result.json"
    result_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
