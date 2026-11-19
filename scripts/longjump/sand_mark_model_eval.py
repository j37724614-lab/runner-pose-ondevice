"""Can a phone-sized segmentation model find the same sand mark as the server?  (plan stage 3)

The server finds the nearest mark in the sand with YOLO26x-seg (TensorRT FP16, 1280 px, minimal
rectangle letterbox) on a crop around the runner (core/longjump/sand_mark.py).  A Core ML model on
the phone has a fixed input size, so it letterboxes the crop to a square, and a smaller model may
be needed for speed.  This runs the server's own find_sand_mark with other models / input sizes
and compares every mark with the server's.

    export LD_LIBRARY_PATH=$CONDA_PREFIX/lib:$TENSORRT_LIB_DIR   # as start_backend.sh does
    /home/jeter/.conda/envs/yolo_new/bin/python scripts/longjump/sand_mark_model_eval.py \
        [--configs x1280rect,s640sq] [--out ~/runner-eval/longjump_port/sand_mark_eval.json]

Cases: every attempt in testdata/longjump/ (dump_longjump_fixtures.py) with a sand landing: the 27
GT jumps (4K; the server skips the mark there only because they have no pit calibration) and the
backend sessions (1080p, pit calibration: the mark's distance error in metres).  The weights of
the smaller models are downloaded by Ultralytics into --weights-dir on first use.

Metrics per config: same frame / same body part / |dx| px of the mark (x is what the distance
uses), for the sessions |delta distance| in cm through the pit homography, and model GFLOPs.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES = REPO_ROOT / "testdata" / "longjump"
WEIGHTS_DIR = Path.home() / "runner-eval" / "longjump_port" / "seg_models"
OUT_DEFAULT = Path.home() / "runner-eval" / "longjump_port" / "sand_mark_eval.json"

# name -> (weights, image size, square letterbox?)
CONFIGS = {
    "x1280rect_pt": ("yolo26x-seg.pt", 1280, False),  # server model as PyTorch: engine vs .pt
    "x640sq": ("yolo26x-seg.pt", 640, True),
    "l640sq": ("yolo26l-seg.pt", 640, True),
    "m640sq": ("yolo26m-seg.pt", 640, True),
    "s640sq": ("yolo26s-seg.pt", 640, True),
    "n640sq": ("yolo26n-seg.pt", 640, True),
    "l960sq": ("yolo26l-seg.pt", 960, True),
    "m960sq": ("yolo26m-seg.pt", 960, True),
    "s960sq": ("yolo26s-seg.pt", 960, True),
}


def pipeline_root() -> Path:
    root = Path(
        os.environ.get("RUNNER_ANALYSIS_PIPELINE_ROOT", REPO_ROOT.parent / "runner-analysis-pipeline")
    )
    if not (root / "core" / "longjump" / "sand_mark.py").is_file():
        sys.exit(f"pipeline checkout not found at {root}; set RUNNER_ANALYSIS_PIPELINE_ROOT")
    return root


def make_segmenter(weights: Path, image_size: int, square: bool):
    """RunnerSegmenter with another model / size; square=True letterboxes every crop to a square
    (what a fixed-size Core ML model does) instead of the minimal rectangle."""
    from core.longjump.sand_mark import RunnerSegmenter, SandMarkRule

    class EvalSegmenter(RunnerSegmenter):
        def runner_masks(self, frames, runner_boxes):
            rois = [self._roi(frame, box) for frame, box in zip(frames, runner_boxes)]
            wanted = [i for i, roi in enumerate(rois) if roi is not None]
            masks = [None] * len(frames)
            if not wanted:
                return masks
            crops = [frames[i][rois[i][1] : rois[i][3], rois[i][0] : rois[i][2]] for i in wanted]
            results = self.model.predict(
                crops,
                imgsz=self.rule.image_size,
                conf=self.rule.person_confidence,
                classes=[0],
                retina_masks=True,
                half=self.rule.half,
                batch=len(crops),
                rect=not square,
                verbose=False,
            )
            for i, result in zip(wanted, results):
                masks[i] = self._mask_from(result, frames[i], runner_boxes[i], rois[i])
            return masks

    rule = SandMarkRule(image_size=image_size)
    return EvalSegmenter(rule, weights=weights), rule


def load_cases(only: str | None) -> list[dict]:
    from core.longjump.detection import find_trim_end, load_pose_track_from_keypoints
    from core.longjump.pit_homography import PitCalibration, PitHomography

    cases = []
    for folder in sorted(p for p in FIXTURES.iterdir() if (p / "case.json").exists()):
        if only and only not in folder.name:
            continue
        case = json.loads((folder / "case.json").read_text())
        result = json.loads((folder / "result.json").read_text())
        landing = ((result.get("events") or {}).get("sand_landing") or {}).get("frame")
        if landing is None:
            continue
        track = load_pose_track_from_keypoints(folder / "pose" / "keypoints_2d.json", case["camera_index"])
        track = track.until(find_trim_end(track).end_index)
        homography = None
        if case["pit"]:
            pit = case["pit"]
            homography = PitHomography(
                PitCalibration(np.array(pit["image_points"]), np.array(pit["world_points"]), pit["board_offset_m"])
            )
        heights = track.box_heights
        cases.append(
            {
                "name": folder.name,
                "video": Path(case["video"]),
                "track": track,
                "landing": int(landing),
                "side": result["run_direction"],
                "homography": homography,
                "body_px": float(np.nanmedian(heights)),
            }
        )
    return cases


def find_mark(case: dict, segmenter, rule):
    from core.longjump.sand_mark import find_sand_mark

    started = time.perf_counter()
    mark = find_sand_mark(
        case["video"], case["track"], case["landing"], case["side"], rule=rule, segmenter=segmenter
    )
    return mark, time.perf_counter() - started


def mark_record(case: dict, mark) -> dict | None:
    if mark is None:
        return None
    record = {
        "frame": mark.frame,
        "image_px": list(mark.image_px),
        "body_part": mark.body_part,
        "frames_searched": mark.frames_searched,
    }
    if case["homography"] is not None:
        record["world_x"] = float(case["homography"].to_world(np.asarray(mark.image_px, float))[0][0])
    return record


def compare(reference: dict | None, other: dict | None) -> dict:
    if reference is None or other is None:
        return {"both": reference is None and other is None, "missing": other is None}
    out = {
        "same_frame": reference["frame"] == other["frame"],
        "same_body_part": reference["body_part"] == other["body_part"],
        "dx_px": abs(reference["image_px"][0] - other["image_px"][0]),
        "dy_px": abs(reference["image_px"][1] - other["image_px"][1]),
    }
    if "world_x" in reference:
        out["d_distance_cm"] = round(abs(reference["world_x"] - other["world_x"]) * 100, 2)
    return out


def summarise(name: str, rows: list[dict]) -> dict:
    compared = [r["compare"] for r in rows if "dx_px" in r["compare"]]
    missing = sum(1 for r in rows if r["compare"].get("missing"))
    dx = np.array([c["dx_px"] for c in compared]) if compared else np.array([np.nan])
    rel = np.array([r["compare"]["dx_px"] / r["body_px"] for r in rows if "dx_px" in r["compare"]] or [np.nan])
    dist = [c["d_distance_cm"] for c in compared if "d_distance_cm" in c]
    return {
        "config": name,
        "cases": len(rows),
        "missing_mark": missing,
        "same_frame": sum(c["same_frame"] for c in compared),
        "same_body_part": sum(c["same_body_part"] for c in compared),
        "dx_px_median": float(np.median(dx)),
        "dx_px_max": float(np.max(dx)),
        "dx_over_body_height_max": float(np.max(rel)),
        "exact_x": int(np.sum(dx == 0)),
        "within_5px": int(np.sum(dx <= 5)),
        "sessions_d_distance_cm": dist,
        "seconds_per_frame": float(
            np.sum([r["seconds"] for r in rows]) / max(1, np.sum([(r["mark"] or {}).get("frames_searched", 0) for r in rows]))
        ),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--configs", help="comma-separated names (default: all)")
    parser.add_argument("--only", help="substring of the case names")
    parser.add_argument("--weights-dir", type=Path, default=WEIGHTS_DIR)
    parser.add_argument("--out", type=Path, default=OUT_DEFAULT)
    args = parser.parse_args()

    pipeline = pipeline_root()
    sys.path.insert(0, str(pipeline))
    from scripts.eval.common import require_tensorrt

    require_tensorrt()
    args.weights_dir.mkdir(parents=True, exist_ok=True)
    os.chdir(args.weights_dir)  # Ultralytics downloads missing weights into the working directory

    from core.longjump.sand_mark import RunnerSegmenter, SandMarkRule

    cases = load_cases(args.only)
    print(f"[sand-eval] {len(cases)} cases with a sand landing", flush=True)
    reference_segmenter = RunnerSegmenter().warm_up()  # production: TensorRT engine, 1280 rect
    reference = {}
    for case in cases:
        mark, seconds = find_mark(case, reference_segmenter, SandMarkRule())
        reference[case["name"]] = {"mark": mark_record(case, mark), "seconds": seconds}
    names = args.configs.split(",") if args.configs else list(CONFIGS)
    report = {"reference": "production RunnerSegmenter (yolo26x-seg TensorRT FP16, 1280, rect)", "configs": {}}
    report["reference_marks"] = reference
    for name in names:
        weights_name, image_size, square = CONFIGS[name]
        weights = args.weights_dir / weights_name
        if weights_name == "yolo26x-seg.pt":
            weights = pipeline / "models" / weights_name
        segmenter, rule = make_segmenter(Path(weights_name) if not weights.exists() else weights, image_size, square)
        segmenter.warm_up()
        try:
            gflops = float(segmenter.model.info(verbose=False)[3])
        except Exception:  # noqa: BLE001 -- informational only
            gflops = None
        rows = []
        for case in cases:
            mark, seconds = find_mark(case, segmenter, rule)
            record = mark_record(case, mark)
            rows.append(
                {
                    "case": case["name"],
                    "mark": record,
                    "seconds": seconds,
                    "body_px": case["body_px"],
                    "compare": compare(reference[case["name"]]["mark"], record),
                }
            )
        summary = summarise(name, rows)
        summary["gflops_640"] = gflops
        report["configs"][name] = {"summary": summary, "rows": rows}
        print(f"[sand-eval] {json.dumps(summary)}", flush=True)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=1, ensure_ascii=False, default=str))
    print(f"[sand-eval] -> {args.out}")


if __name__ == "__main__":
    main()
