#!/usr/bin/env python3
"""Compare on-device keypoints against desktop ground truth (規劃書 §07).

Alignment rule (規劃書 §07 對齊策略): the device exports the exact bbox it used
per frame; `make_ground_truth.py` re-runs desktop HRNet on the *same* bbox. So this
script only compares two keypoint sets that are already on the same crop — any
difference is model / conversion / FP16 / DarkPose-port, never detector mismatch.

Inputs
  --device  runs/<device>/<cu>/<video>_kpts.json   (RunnerPoseKit export, see schema below)
  --truth   runs/ground_truth/<video>_kpts.npz     (make_ground_truth.py)
Output
  per-joint pixel-error table + PCK@0.05 + JSON summary under --out

Device JSON schema (one object):
  { "video": str, "fps": float, "frame_size": [w, h],
    "frames": [ { "frame": int, "valid": bool, "bbox": [x1,y1,x2,y2],
                  "bbox_extrapolated": bool,
                  "joints": [[x, y, score], ... 23] }, ... ] }
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

JOINT_NAMES = [
    "nose", "left_eye", "right_eye", "left_ear", "right_ear",
    "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
    "left_wrist", "right_wrist", "left_hip", "right_hip",
    "left_knee", "right_knee", "left_ankle", "right_ankle",
    "left_big_toe", "left_small_toe", "left_heel",
    "right_big_toe", "right_small_toe", "right_heel",
]
FOOT_JOINTS = set(range(17, 23))


def load_device(path: Path):
    doc = json.loads(path.read_text())
    frames = {f["frame"]: f for f in doc["frames"]}
    return doc, frames


def load_truth(path: Path):
    z = np.load(path, allow_pickle=True)
    # kpts: (N, 23, 2), frame_index: (N,), bbox: (N, 4)
    return {int(fi): (z["kpts"][i], z["bbox"][i]) for i, fi in enumerate(z["frame_index"])}


def bbox_diag(bbox) -> float:
    x1, y1, x2, y2 = bbox
    return float(np.hypot(x2 - x1, y2 - y1))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", type=Path, required=True)
    ap.add_argument("--truth", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--pck", type=float, default=0.05, help="PCK threshold as fraction of bbox diagonal")
    ap.add_argument("--exclude-extrapolated", action="store_true",
                    help="drop frames whose device bbox came from the tracker (isolate detector-cadence effect)")
    args = ap.parse_args()

    _, dev_frames = load_device(args.device)
    truth = load_truth(args.truth)
    args.out.mkdir(parents=True, exist_ok=True)

    per_joint_err: list[list[float]] = [[] for _ in JOINT_NAMES]
    pck_hits = np.zeros(len(JOINT_NAMES))
    pck_total = np.zeros(len(JOINT_NAMES))
    n_frames = 0

    for fi, df in dev_frames.items():
        if not df.get("valid", False) or fi not in truth:
            continue
        if args.exclude_extrapolated and df.get("bbox_extrapolated", False):
            continue
        dev_kpts = np.asarray([j[:2] for j in df["joints"]], dtype=np.float64)
        tk, tb = truth[fi]
        diag = bbox_diag(df.get("bbox") or tb)
        thr = args.pck * diag
        d = np.linalg.norm(dev_kpts - np.asarray(tk, dtype=np.float64), axis=1)
        n_frames += 1
        for j in range(len(JOINT_NAMES)):
            per_joint_err[j].append(float(d[j]))
            pck_total[j] += 1
            if d[j] <= thr:
                pck_hits[j] += 1

    def stats(vals: list[float]) -> dict:
        a = np.asarray(vals) if vals else np.zeros(1)
        return {
            "n": len(vals),
            "mean": float(a.mean()),
            "p50": float(np.percentile(a, 50)),
            "p90": float(np.percentile(a, 90)),
            "max": float(a.max()),
        }

    all_err = [e for lst in per_joint_err for e in lst]
    foot_err = [e for j in FOOT_JOINTS for e in per_joint_err[j]]
    summary = {
        "device_file": str(args.device),
        "truth_file": str(args.truth),
        "frames_compared": n_frames,
        "exclude_extrapolated": args.exclude_extrapolated,
        "pck_threshold": args.pck,
        "overall": stats(all_err),
        "foot_joints": stats(foot_err),
        "pck_overall": float(pck_hits.sum() / max(pck_total.sum(), 1)),
        "per_joint": {
            JOINT_NAMES[j]: {
                **stats(per_joint_err[j]),
                "pck": float(pck_hits[j] / max(pck_total[j], 1)),
            }
            for j in range(len(JOINT_NAMES))
        },
    }
    (args.out / "accuracy_summary.json").write_text(json.dumps(summary, indent=2))

    print(f"frames compared: {n_frames}")
    print(f"overall  mean {summary['overall']['mean']:.2f}px  p90 {summary['overall']['p90']:.2f}px"
          f"  PCK@{args.pck} {summary['pck_overall']:.3f}")
    print(f"foot     mean {summary['foot_joints']['mean']:.2f}px  p90 {summary['foot_joints']['p90']:.2f}px")
    print(f"\n{'joint':<16} {'mean':>7} {'p90':>7} {'max':>7} {'pck':>6}")
    for j, name in enumerate(JOINT_NAMES):
        s = summary["per_joint"][name]
        print(f"{name:<16} {s['mean']:>7.2f} {s['p90']:>7.2f} {s['max']:>7.2f} {s['pck']:>6.3f}")
    print(f"\nwrote {args.out / 'accuracy_summary.json'}")


if __name__ == "__main__":
    main()
