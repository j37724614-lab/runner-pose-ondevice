"""Convert a SimCC pose model (RTMPose ...) to Core ML and write its pose model spec.

Input: a TorchScript file of the model that takes a normalised float crop [1, 3, H, W] and
returns (simcc_x [1, K, W*r], simcc_y [1, K, H*r]). README.md shows how to export one from an
MMPose environment. The converter:
  1. wraps it so Core ML takes a 0-255 image and does the mean/std normalisation itself;
  2. converts to an ML Program `.mlpackage` (image input `person_crop`, outputs `simcc_x`,
     `simcc_y`), Float16 by default;
  3. checks the wrapper against the original model in PyTorch, and on macOS also runs the
     Core ML model and compares;
  4. writes a spec JSON from the pipeline's RTMPose template, validated with the pipeline's
     parser, plus a conversion report.

    python scripts/pose_models/convert_rtmpose_to_coreml.py \
        --torchscript rtmpose.torchscript.pt --id rtmpose_m_wholebody \
        --input-size 192 256 --split-ratio 2.0 --out-dir build/pose_models

    python scripts/pose_models/convert_rtmpose_to_coreml.py --self-test --out-dir /tmp/x
        # converts a tiny random SimCC network: checks the converter itself on any machine

Then copy the spec into the pipeline's core/pose_models/specs/ (the source of truth), run
sync_pose_specs.py, and put the .mlpackage in Sources/RunnerPoseKit/Resources/.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import platform
import sys
from pathlib import Path

import numpy as np
import torch
from pipeline_specs import pipeline_spec_dir, spec_module
from torch import nn

TEMPLATE = "rtmpose_wholebody_template.json"
INPUT_NAME = "person_crop"


class NormalisedInput(nn.Module):
    """0-255 image in, model's normalisation applied, SimCC vectors out."""

    def __init__(self, model: nn.Module, mean: list[float], std: list[float]) -> None:
        super().__init__()
        self.model = model
        self.register_buffer("mean", torch.tensor(mean, dtype=torch.float32).reshape(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(std, dtype=torch.float32).reshape(1, 3, 1, 1))

    def forward(self, image_0_255: torch.Tensor):
        simcc_x, simcc_y = self.model((image_0_255 - self.mean) / self.std)
        return simcc_x, simcc_y


class TinySimCC(nn.Module):
    """Small random SimCC network for --self-test; same input and output contract as RTMPose."""

    def __init__(self, keypoints: int, width: int, height: int, ratio: float) -> None:
        super().__init__()
        self.keypoints = keypoints
        self.x_bins, self.y_bins = int(width * ratio), int(height * ratio)
        self.features = nn.Sequential(
            nn.Conv2d(3, 8, 3, stride=4, padding=1), nn.ReLU(), nn.AdaptiveAvgPool2d(1)
        )
        self.to_x = nn.Linear(8, keypoints * self.x_bins)
        self.to_y = nn.Linear(8, keypoints * self.y_bins)

    def forward(self, x):
        f = self.features(x).flatten(1)
        return (
            self.to_x(f).reshape(1, self.keypoints, self.x_bins),
            self.to_y(f).reshape(1, self.keypoints, self.y_bins),
        )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--torchscript", type=Path, help="TorchScript of the SimCC model")
    source.add_argument("--self-test", action="store_true", help="convert a tiny random model")
    parser.add_argument("--id", default="rtmpose_selftest", help="spec id of the new model")
    parser.add_argument(
        "--input-size", type=int, nargs=2, metavar=("W", "H"), help="crop size (default: template)"
    )
    parser.add_argument("--split-ratio", type=float, help="SimCC split ratio (default: template)")
    parser.add_argument("--color-order", choices=("RGB", "BGR"), default="RGB")
    parser.add_argument("--precision", choices=("float16", "float32"), default="float16")
    parser.add_argument("--minimum-ios", type=int, default=16)
    parser.add_argument("--out-dir", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    import coremltools as ct

    spec_code = spec_module()
    template = json.loads((pipeline_spec_dir() / TEMPLATE).read_text(encoding="utf-8"))
    width, height = args.input_size or (template["input"]["width"], template["input"]["height"])
    ratio = args.split_ratio or template["output"]["simcc"]["split_ratio"]
    norm = template["input"]["normalization"]

    if args.self_test:
        torch.manual_seed(0)
        model = TinySimCC(23, width, height, ratio).eval()
        source_desc, source_sha = "self-test TinySimCC", None
    else:
        model = torch.jit.load(str(args.torchscript), map_location="cpu").eval()
        source_desc, source_sha = str(args.torchscript), sha256_file(args.torchscript)

    wrapped = NormalisedInput(model, norm["mean"], norm["std"]).eval()
    example = torch.rand(1, 3, height, width) * 255.0
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)
        ref_x, ref_y = wrapped(example)
        tr_x, tr_y = traced(example)
    keypoints = int(ref_x.shape[1])
    if ref_x.shape[2] != round(width * ratio) or ref_y.shape[2] != round(height * ratio):
        sys.exit(
            f"model output {tuple(ref_x.shape)}/{tuple(ref_y.shape)} does not match input "
            f"{width}x{height} with split ratio {ratio}; check --input-size / --split-ratio"
        )
    trace_error = float(max((ref_x - tr_x).abs().max(), (ref_y - tr_y).abs().max()))

    precision = ct.precision.FLOAT16 if args.precision == "float16" else ct.precision.FLOAT32
    layout = ct.colorlayout.RGB if args.color_order == "RGB" else ct.colorlayout.BGR
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.ImageType(name=INPUT_NAME, shape=(1, 3, height, width), scale=1.0, color_layout=layout)],
        outputs=[ct.TensorType(name="simcc_x"), ct.TensorType(name="simcc_y")],
        minimum_deployment_target=getattr(ct.target, f"iOS{args.minimum_ios}"),
        compute_precision=precision,
    )
    package_name = f"{args.id}.mlpackage"
    args.out_dir.mkdir(parents=True, exist_ok=True)
    package_path = args.out_dir / package_name
    mlmodel.save(str(package_path))

    coreml_check = "not run (Core ML predictions need macOS)"
    if platform.system() == "Darwin":
        from PIL import Image

        pixels = example[0].permute(1, 2, 0).numpy().astype(np.uint8)
        with torch.no_grad():
            ref_x, ref_y = wrapped(torch.from_numpy(pixels).permute(2, 0, 1)[None].float())
        out = mlmodel.predict({INPUT_NAME: Image.fromarray(pixels)})
        error = max(
            float(np.abs(out["simcc_x"] - ref_x.numpy()).max()),
            float(np.abs(out["simcc_y"] - ref_y.numpy()).max()),
        )
        coreml_check = f"max abs error vs PyTorch {error:.4g}"

    spec = copy.deepcopy(template)
    spec.update(
        id=args.id,
        status="experimental",
        description=f"Converted from {source_desc} by convert_rtmpose_to_coreml.py.",
    )
    spec["keypoints"]["count"] = keypoints
    if keypoints < 23:
        sys.exit(
            f"model predicts {keypoints} keypoints; edit keypoints.to_canonical by hand for a "
            "layout other than COCO-WholeBody"
        )
    spec["input"].update(width=width, height=height, color_order=args.color_order)
    spec["output"]["simcc"]["split_ratio"] = ratio
    spec["coreml"].update(package=package_name, compute_precision=args.precision)
    spec["coreml"]["converter"] = "runner-pose-ondevice: scripts/pose_models/convert_rtmpose_to_coreml.py"
    if source_sha:
        spec["coreml"]["source_sha256"] = source_sha
    spec_code.parse_spec(spec, source=f"{args.id} (generated)")  # same rules as the pipeline
    spec_path = args.out_dir / f"{args.id}.json"
    spec_path.write_text(json.dumps(spec, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    report = {
        "source": source_desc,
        "source_sha256": source_sha,
        "keypoints": keypoints,
        "input": [width, height],
        "split_ratio": ratio,
        "simcc_bins": [int(ref_x.shape[2]), int(ref_y.shape[2])],
        "torchscript_trace_max_abs_error": trace_error,
        "coreml_check": coreml_check,
        "coremltools_version": ct.__version__,
        "torch_version": torch.__version__,
        "compute_precision": args.precision,
        "minimum_ios": args.minimum_ios,
        "package": str(package_path),
        "spec": str(spec_path),
    }
    (args.out_dir / f"{args.id}.conversion.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
