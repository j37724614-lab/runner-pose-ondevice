#!/usr/bin/env python3
"""Produce the S0 parity baseline for each candidate detector scale (規劃書 §05 P0 / §08).

For every video and every scale in --scales, this samples frames with the stock
`yolo26<scale>.pt` (COCO, person class only), applies the same qualification rule as
the pipeline's prescan (`height >= min_height`, `conf >= conf`), and writes the merged
valid ranges to:

  testdata/prescan_reference/<scale>/<video_stem>_valid_ranges.json

`PrescanParityTests` (Swift) loads these and checks `PrescanFilter` against them,
tolerating +/- buffer at the range edges.

No clipped video is written (unlike the desktop prescan_filter_valid_video.py) — the
Swift S0 works on ranges, not files.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import cv2  # type: ignore
import numpy as np  # type: ignore

from prescan_merge import merge_hit_frames

PERSON_CLASS = 0


def scan_video(video: Path, model, *, stride: int, imgsz: int, conf: float,
               iou: float, min_height: float, use_grab: bool) -> dict:
    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        raise RuntimeError(f"cannot open {video}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 60.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)

    hit_frames: list[int] = []
    sampled = 0
    t0 = time.perf_counter()
    idx = 0
    while idx < total:
        if idx % stride == 0:
            ok, frame = cap.read()
            if not ok:
                break
            sampled += 1
            res = model.predict(frame, imgsz=imgsz, conf=conf, iou=iou,
                                classes=[PERSON_CLASS], verbose=False)[0]
            hit = False
            if res.boxes is not None and len(res.boxes):
                xyxy = res.boxes.xyxy.cpu().numpy()
                for x1, y1, x2, y2 in xyxy[:, :4]:
                    if (y2 - y1) >= min_height:
                        hit = True
                        break
            if hit:
                hit_frames.append(idx)
        else:
            ok = cap.grab() if use_grab else cap.read()[0]
            if not ok:
                break
        idx += 1
    cap.release()
    elapsed = time.perf_counter() - t0

    buffer_frames = int(round(1.0 * fps))
    max_gap_frames = int(round(1.0 * fps))
    ranges = merge_hit_frames(hit_frames, total, stride, buffer_frames, max_gap_frames)
    kept = sum(r["num_frames"] for r in ranges)

    return {
        "video": str(video),
        "video_info": {"width": w, "height": h, "fps": fps, "total_frames": total},
        "params": {
            "stride": stride, "imgsz": imgsz, "conf": conf, "iou": iou,
            "min_height": min_height, "buffer_frames": buffer_frames,
            "max_gap_frames": max_gap_frames,
        },
        "ranges": ranges,
        "summary": {
            "num_ranges": len(ranges),
            "sampled": sampled,
            "hits": len(hit_frames),
            "kept_frames": kept,
            "kept_ratio": kept / total if total else 0.0,
            "scan_seconds": elapsed,
        },
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--videos", type=Path, default=Path("testdata/videos"))
    ap.add_argument("--out", type=Path, default=Path("testdata/prescan_reference"))
    ap.add_argument("--scales", nargs="+", default=["n", "s", "m", "l"])
    ap.add_argument("--stride", type=int, default=8)
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--conf", type=float, default=0.25)
    ap.add_argument("--iou", type=float, default=0.7)
    ap.add_argument("--min-height", type=float, default=40.0,
                    help="TODO(confirm): copy the production backend value (規劃書 §12)")
    ap.add_argument("--no-grab", action="store_true")
    args = ap.parse_args()

    from ultralytics import YOLO  # type: ignore

    videos = sorted(p for p in args.videos.iterdir()
                    if p.suffix.lower() in {".mp4", ".mov", ".m4v", ".avi"})
    if not videos:
        raise SystemExit(f"no videos in {args.videos}")

    for scale in args.scales:
        model = YOLO(f"yolo26{scale}.pt")
        out_dir = args.out / scale
        out_dir.mkdir(parents=True, exist_ok=True)
        for video in videos:
            report = scan_video(
                video, model,
                stride=args.stride, imgsz=args.imgsz, conf=args.conf, iou=args.iou,
                min_height=args.min_height, use_grab=not args.no_grab,
            )
            dst = out_dir / f"{video.stem}_valid_ranges.json"
            dst.write_text(json.dumps(report, indent=2))
            s = report["summary"]
            print(f"[{scale}] {video.name}: {s['num_ranges']} ranges, "
                  f"kept {s['kept_ratio']:.1%}, {s['scan_seconds']:.1f}s -> {dst}")


if __name__ == "__main__":
    main()
