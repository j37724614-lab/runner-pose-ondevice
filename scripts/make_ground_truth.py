#!/usr/bin/env python3
"""Desktop HRNet keypoints on the *device's own* per-frame bbox (規劃書 §07).

Reads the RunnerPoseKit device export (per-frame bbox), re-runs the pipeline's HRNet
(PyTorch, FP32) on the same crop for each frame, and writes an .npz that
`compare_accuracy.py` consumes. Because both sides use the identical bbox + identical
`box_to_center_scale` / `get_affine_transform` / `get_final_preds_dark`, the only thing
left to differ is the model itself (conversion + FP16 + Swift DarkPose port).

Requires a working runner-analysis-pipeline checkout: pass --pipeline-root.
Run this in the pipeline's own environment (torch + its HRNet deps).

Device export schema: see compare_accuracy.py docstring.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cv2  # type: ignore
import numpy as np  # type: ignore


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pipeline-root", type=Path, required=True,
                    help="path to a runner-analysis-pipeline checkout")
    ap.add_argument("--video", type=Path, required=True)
    ap.add_argument("--device-export", type=Path, required=True,
                    help="RunnerPoseKit <video>_kpts.json with per-frame bbox")
    ap.add_argument("--checkpoint", type=Path, default=None,
                    help="HRNet .pth (defaults to the pipeline's wholebody23 checkpoint)")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    root = args.pipeline_root.resolve()
    demo = root / "MotionAGFormer" / "demo"
    sys.path.insert(0, str(demo))

    import torch  # type: ignore
    from lib.hrnet.lib.config import cfg  # type: ignore
    from lib.hrnet.lib.models import pose_hrnet  # type: ignore
    from lib.hrnet.lib.utils.utilitys import PreProcess  # type: ignore
    from lib.hrnet.lib.utils.inference import get_final_preds_dark  # type: ignore

    config_path = demo / "lib/hrnet/experiments/w48_384x288_wholebody23_dark.yaml"
    checkpoint = args.checkpoint or (
        root / "data/runner_wholebody23/exports/"
        "pose_hrnet_w48_wholebody23_384x288_dark_jump_broadcast_long_triple_pilot300_headonly_epoch3.pth"
    )

    model_cfg = cfg.clone()
    model_cfg.defrost()
    model_cfg.merge_from_file(str(config_path))
    model_cfg.freeze()
    model = pose_hrnet.get_pose_net(model_cfg, is_train=False)
    model.load_state_dict(torch.load(checkpoint, map_location="cpu", weights_only=True), strict=True)
    model.eval()

    export = json.loads(args.device_export.read_text())
    frames_by_idx = {f["frame"]: f for f in export["frames"] if f.get("valid")}

    cap = cv2.VideoCapture(str(args.video))
    if not cap.isOpened():
        raise SystemExit(f"cannot open {args.video}")

    out_kpts, out_bbox, out_fi = [], [], []
    idx = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        f = frames_by_idx.get(idx)
        if f is not None:
            bbox = [float(v) for v in f["bbox"]]
            inputs, _, center, scale = PreProcess(frame, [bbox], model_cfg, 1)
            inputs = inputs[:, [2, 1, 0]]
            with torch.no_grad():
                heat = model(inputs)
            preds, _ = get_final_preds_dark(
                model_cfg, heat.cpu().numpy(), np.asarray(center), np.asarray(scale)
            )
            out_kpts.append(preds[0])
            out_bbox.append(bbox)
            out_fi.append(idx)
        idx += 1
    cap.release()

    args.out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        args.out,
        kpts=np.asarray(out_kpts, dtype=np.float32),
        bbox=np.asarray(out_bbox, dtype=np.float32),
        frame_index=np.asarray(out_fi, dtype=np.int32),
    )
    print(f"wrote {len(out_fi)} frames -> {args.out}")


if __name__ == "__main__":
    main()
