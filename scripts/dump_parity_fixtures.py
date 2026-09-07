#!/usr/bin/env python3
"""Generate parity fixtures for the Swift unit tests (規劃書 §05 P1).

For a handful of (frame, bbox) pairs this dumps everything the Swift side needs to
prove `Geometry` and `HeatmapDecoder` match the pipeline to sub-pixel:

  Tests/RunnerPoseKitTests/Fixtures/
    <name>.crop.png              288x384 RGB crop fed to the model
    <name>.heatmap.f32           raw float32, shape [23,96,72], row-major
    <name>.geometry.json         { frame_size, bbox, center, scale,
                                   forward_affine[6], inverse_affine_hm[6] }
    <name>.keypoints.json        expected 23x [x, y, score] in ORIGINAL frame pixels
    manifest.json                list of fixture names + notes

Run in the pipeline's environment. Pick bboxes that cover: centred runner, runner
near a frame edge, small (far) runner, large (near) runner.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

import cv2  # type: ignore
import numpy as np  # type: ignore


def get_affine_np(center, scale, output_size, inv):
    """Mirror transforms.get_affine_transform(rot=0) and return the 2x3 as 6 floats."""
    scale_tmp = np.asarray(scale, dtype=np.float64) * 200.0
    src_w = scale_tmp[0]
    dst_w, dst_h = output_size
    src_dir = np.array([0.0, src_w * -0.5])
    dst_dir = np.array([0.0, dst_w * -0.5])
    src = np.zeros((3, 2)); dst = np.zeros((3, 2))
    src[0] = center
    src[1] = center + src_dir
    dst[0] = [dst_w * 0.5, dst_h * 0.5]
    dst[1] = dst[0] + dst_dir

    def third(a, b):
        d = a - b
        return b + np.array([-d[1], d[0]])

    src[2] = third(src[0], src[1])
    dst[2] = third(dst[0], dst[1])
    m = cv2.getAffineTransform(np.float32(dst if inv else src), np.float32(src if inv else dst))
    return [float(x) for x in m.reshape(-1)]  # a b tx c d ty


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pipeline-root", type=Path, required=True)
    ap.add_argument("--video", type=Path, required=True)
    ap.add_argument("--cases", type=Path, required=True,
                    help="JSON: [ {name, frame, bbox:[x1,y1,x2,y2]}, ... ]")
    ap.add_argument("--out", type=Path,
                    default=Path("Tests/RunnerPoseKitTests/Fixtures"))
    args = ap.parse_args()

    demo = args.pipeline_root.resolve() / "MotionAGFormer" / "demo"
    sys.path.insert(0, str(demo))
    import torch  # type: ignore
    from lib.hrnet.lib.config import cfg  # type: ignore
    from lib.hrnet.lib.models import pose_hrnet  # type: ignore
    from lib.hrnet.lib.utils.utilitys import PreProcess, box_to_center_scale  # type: ignore
    from lib.hrnet.lib.utils.inference import get_final_preds_dark  # type: ignore

    config_path = demo / "lib/hrnet/experiments/w48_384x288_wholebody23_dark.yaml"
    checkpoint = (args.pipeline_root / "data/runner_wholebody23/exports/"
                  "pose_hrnet_w48_wholebody23_384x288_dark_jump_broadcast_long_triple_pilot300_headonly_epoch3.pth")

    mc = cfg.clone(); mc.defrost(); mc.merge_from_file(str(config_path)); mc.freeze()
    model = pose_hrnet.get_pose_net(mc, is_train=False)
    model.load_state_dict(torch.load(checkpoint, map_location="cpu", weights_only=True), strict=True)
    model.eval()

    cases = json.loads(args.cases.read_text())
    args.out.mkdir(parents=True, exist_ok=True)
    manifest = []

    cap = cv2.VideoCapture(str(args.video))
    for case in cases:
        cap.set(cv2.CAP_PROP_POS_FRAMES, case["frame"])
        ok, frame = cap.read()
        if not ok:
            print(f"skip {case['name']}: cannot read frame {case['frame']}")
            continue
        h, w = frame.shape[:2]
        bbox = [float(v) for v in case["bbox"]]

        # verbatim: box_to_center_scale(bbox, shape[0]=H, shape[1]=W)
        center, scale = box_to_center_scale(bbox, h, w)

        inputs, _, centers, scales = PreProcess(frame, [bbox], mc, 1)
        inputs_rgb = inputs[:, [2, 1, 0]]
        with torch.no_grad():
            heat = model(inputs_rgb).cpu().numpy()[0]  # [23,96,72]
        preds, maxvals = get_final_preds_dark(
            mc, heat[None], np.asarray(centers), np.asarray(scales)
        )
        kpts = preds[0]                # [23,2] original-frame px
        scores = maxvals[0].reshape(-1)

        # the actual 288x384 crop the model saw (BGR warp -> save as RGB png)
        from lib.hrnet.lib.utils.transforms import get_affine_transform  # type: ignore
        trans = get_affine_transform(np.asarray(center), np.asarray(scale), 0, mc.MODEL.IMAGE_SIZE)
        crop_bgr = cv2.warpAffine(frame, trans, (288, 384), flags=cv2.INTER_LINEAR)
        cv2.imwrite(str(args.out / f"{case['name']}.crop.png"),
                    cv2.cvtColor(crop_bgr, cv2.COLOR_BGR2RGB))

        with open(args.out / f"{case['name']}.heatmap.f32", "wb") as fh:
            fh.write(struct.pack("<%df" % heat.size, *heat.astype(np.float32).reshape(-1)))

        (args.out / f"{case['name']}.geometry.json").write_text(json.dumps({
            "frame_size": [w, h],
            "bbox": bbox,
            "center": [float(center[0]), float(center[1])],
            "scale": [float(scale[0]), float(scale[1])],
            "forward_affine_crop": get_affine_np(center, scale, [288, 384], inv=0),
            "inverse_affine_heatmap": get_affine_np(center, scale, [72, 96], inv=1),
        }, indent=2))

        (args.out / f"{case['name']}.keypoints.json").write_text(json.dumps([
            [float(kpts[j, 0]), float(kpts[j, 1]), float(scores[j])] for j in range(23)
        ], indent=2))

        manifest.append({"name": case["name"], "frame": case["frame"], "bbox": bbox,
                         "note": case.get("note", "")})
        print(f"wrote fixture {case['name']}")

    cap.release()
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
