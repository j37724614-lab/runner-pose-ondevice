"""Record the server's long-jump analysis call by call, as parity fixtures for LongJumpKit.

LongJumpKit (Sources/LongJumpKit) is the Swift port of runner-analysis-pipeline core/longjump/.
This script runs the server's own ``analyse_long_jump`` on real attempts and records the arguments
and return value of every function the port mirrors, so each Swift function can be checked on the
exact inputs the server saw, and the whole analysis end to end.

    export LD_LIBRARY_PATH=$CONDA_PREFIX/lib:$TENSORRT_LIB_DIR   # as start_backend.sh does
    /home/jeter/.conda/envs/yolo_new/bin/python \
        scripts/longjump/dump_longjump_fixtures.py [--only gt_03]

The sessions' sand mark needs the TensorRT segmentation engine, exactly as in production; the
script stops when TensorRT cannot be imported instead of recording a silent fallback.

Cases:
  gt_NN_*       the 27 jumps of the 16Pro CVAT ground truth (4K; no pit calibration, so no
                distance): pose from the latest ``longjump_gt_eval run`` (--gt-run), first frame
                from the cut segment;
  session_XXXX  backend long-jump sessions (1080p, with the pit calibration rebuilt from the
                backend database by scripts.eval.rebuild_backend_configs, read only).  Their sand
                mark is segmented again (GPU), so the runner masks are recorded too.

Output (gitignored, ~0.8 GB): testdata/longjump/
  index.json                      cases + pipeline commit
  <case>/case.json                inputs, pit calibration, per-track signals
  <case>/pose/keypoints_2d.json   the pose input (copied)
  <case>/first_frame.bgr          raw BGR bytes of the first video frame (width x height x 3)
  <case>/calls.json               every recorded call: {"fn", "args", "result", "after"}
  <case>/result.json              analyse_long_jump's return value (internal "_" keys included)

Encoding: NaN / inf are "nan" / "inf" / "-inf"; a PoseTrack is {"$track": n} (the first n
frames of the case's full track); a full-frame mask is {"$mask": {"width", "height", "runs":
[[row, start, end), ...]]}}; the first frame is {"$image": "first_frame"}; dataclasses carry
"$type"; PitHomography is {"$type": "PitHomography", calibration, matrix, rms_m, x_range}.

Pipeline location: $RUNNER_ANALYSIS_PIPELINE_ROOT, else ../runner-analysis-pipeline.
"""

from __future__ import annotations

import argparse
import dataclasses
import functools
import inspect
import json
import math
import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_DEFAULT = REPO_ROOT / "testdata" / "longjump"
GT_RUN_DEFAULT = Path.home() / "runner-eval" / "longjump_gt" / "current"
GT_SEGMENTS = Path.home() / "runner-eval" / "longjump_gt" / "segments"
CONFIG_WORK = Path.home() / "runner-eval" / "longjump_port"
BACKEND_SESSIONS = ("9b749ffa", "a8ed164a", "38576b6e", "78215c73", "afb6775c", "3217001b")

# module -> functions whose calls are recorded.  Calls go through module globals, so every
# core.longjump module that imported one of these names gets the recording wrapper too.
RECORDED = {
    "core.longjump.detection": (
        "load_pose_track_from_keypoints",
        "read_first_frame",
        "find_trim_end",
        "pit_side_of",
        "detect_board",
        "fit_takeoff_line",
        "find_flight",
        "flight_apex",
        "find_sand_landing",
        "review_sand_landing",
        "_support_run_from_speed",
        "_adaptive_board_contact_from_speed",
        "_select_board_contact_from_speed",
        "find_board_contact",
        "find_toe_off",
        "find_board_contact_with_board",
        "detect_jump_events",
        "takeoff_foot",
        "white_mask",
        "red_runway_mask",
    ),
    "core.longjump.takeoff_board": (
        "board_row_width_px",
        "assess_takeoff",
        "find_partial_board",
        "assess_partial_takeoff",
        "_check_board_line_against_pit",
    ),
    "core.longjump.pit_homography": ("near_end_from_direction",),
    "core.longjump.distance": ("measure_distance",),
    "core.longjump.approach": ("foot_contacts", "_add_approach_points", "approach_profile"),
    "core.longjump.failed_attempt": ("airborne_profile", "analyse_failed_attempt"),
    "core.longjump.result_output": ("overlay_data",),
    "core.longjump.sand_mark": (
        "find_sand_mark",
        "sand_surface_y",
        "board_side_contact",
        "nearest_joint",
        "_nearest_contact_in_batch",
    ),
    "core.longjump.analysis": ("analyse_long_jump",),
}
# Arguments a function changes in place: recorded again after the call ("after").
MUTATED = {
    "_add_approach_points": ("result",),
    "_check_board_line_against_pit": ("result",),
}
# Large intermediate images: only their hash is recorded (the Swift side recomputes it).
HASHED_RESULTS = {"white_mask", "red_runway_mask"}


def pipeline_root() -> Path:
    root = Path(
        os.environ.get("RUNNER_ANALYSIS_PIPELINE_ROOT", REPO_ROOT.parent / "runner-analysis-pipeline")
    )
    if not (root / "core" / "longjump" / "analysis.py").is_file():
        sys.exit(f"pipeline checkout not found at {root}; set RUNNER_ANALYSIS_PIPELINE_ROOT")
    return root


def fnv1a64(data: bytes) -> str:
    h = 0xCBF29CE484222325
    for byte in data:
        h ^= byte
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016x}"


def fnv1a64_rows(array: np.ndarray) -> str:
    """Same as make_unit_fixtures.fnv1a64_rows (LongJumpKit FNV1a64.rows)."""
    rows = np.ascontiguousarray(array, dtype=np.uint8).reshape(array.shape[0], -1)
    h = np.full(rows.shape[0], 0xCBF29CE484222325, dtype=np.uint64)
    prime = np.uint64(0x100000001B3)
    with np.errstate(over="ignore"):
        for column in range(rows.shape[1]):
            h = (h ^ rows[:, column].astype(np.uint64)) * prime
    return fnv1a64(h.astype("<u8").tobytes())


def mask_runs(mask: np.ndarray) -> list:
    runs = []
    rows = np.flatnonzero(np.asarray(mask).any(axis=1))
    for y in rows:
        padded = np.concatenate([[False], np.asarray(mask[y]) != 0, [False]])
        edges = np.flatnonzero(padded[1:] != padded[:-1])
        runs.extend([int(y), int(a), int(b)] for a, b in zip(edges[::2], edges[1::2]))
    return runs


class Recorder:
    """Encodes values and collects the calls of one case."""

    def __init__(self) -> None:
        self.calls: list = []
        self.full_track = None
        self.first_frame: np.ndarray | None = None

    # ---------------------------------------------------------------- encoding
    def encode(self, value):
        from core.longjump.detection import PoseTrack
        from core.longjump.pit_homography import PitHomography

        if value is None or isinstance(value, (str, bool)):
            return value
        if isinstance(value, PoseTrack):
            return {"$track": self._track_prefix(value)}
        if isinstance(value, PitHomography):
            return {
                "$type": "PitHomography",
                "calibration": self.encode(value.calibration),
                "matrix": self.encode(value.matrix),
                "rms_m": self.encode(value.rms_m),
                "x_range": self.encode(value.x_range),
            }
        if dataclasses.is_dataclass(value) and not isinstance(value, type):
            encoded = {"$type": type(value).__name__}
            for field in dataclasses.fields(value):
                encoded[field.name] = self.encode(getattr(value, field.name))
            return encoded
        if isinstance(value, dict):
            return {str(k): self.encode(v) for k, v in value.items()}
        if isinstance(value, (list, tuple)):
            return [self.encode(v) for v in value]
        if isinstance(value, Path):
            return {"$path": str(value)}
        if isinstance(value, np.ndarray):
            return self._encode_array(value)
        if isinstance(value, (np.bool_,)):
            return bool(value)
        if isinstance(value, (np.integer, int)):
            return int(value)
        if isinstance(value, (np.floating, float)):
            value = float(value)
            if math.isnan(value):
                return "nan"
            if math.isinf(value):
                return "inf" if value > 0 else "-inf"
            return value
        if type(value).__name__ in ("RunnerSegmenter", "_RecordingSegmenter"):
            return {"$segmenter": True}
        raise TypeError(f"cannot encode {type(value).__name__}")

    def _encode_array(self, array: np.ndarray):
        if array.ndim == 3 and array.dtype == np.uint8:
            if self.first_frame is not None and array.shape == self.first_frame.shape and (
                array is self.first_frame or np.array_equal(array, self.first_frame)
            ):
                return {"$image": "first_frame"}
            raise TypeError("an image other than the first frame reached a recorded call")
        if array.ndim == 2 and array.size > 4096 and (array.dtype == bool or array.dtype == np.uint8):
            if array.dtype == np.uint8 and array.max(initial=0) > 1:
                raise TypeError("a non-binary uint8 image reached a recorded call")
            return {
                "$mask": {
                    "width": int(array.shape[1]),
                    "height": int(array.shape[0]),
                    "runs": mask_runs(array),
                }
            }
        return self.encode(array.tolist())

    def _track_prefix(self, track) -> int:
        n = len(track.frames)
        full = self.full_track
        if full is None or n > len(full.frames) or not (
            np.array_equal(track.frames, full.frames[:n])
            and np.array_equal(track.boxes, full.boxes[:n], equal_nan=True)
            and np.array_equal(track.joints_xy, full.joints_xy[:n], equal_nan=True)
        ):
            raise TypeError("a PoseTrack that is not a prefix of the case's full track")
        return n

    # ---------------------------------------------------------------- wrapping
    def wrap(self, qualname: str, fn):
        signature = inspect.signature(fn)
        name = qualname.rsplit(".", 1)[1]
        recorder = self

        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            bound = signature.bind(*args, **kwargs)
            bound.apply_defaults()
            if name == "_nearest_contact_in_batch":
                return recorder._record_batch(fn, qualname, bound)
            entry = {"fn": qualname, "args": {k: recorder.encode(v) for k, v in bound.arguments.items()}}
            result = fn(*bound.args, **bound.kwargs)
            if name == "load_pose_track_from_keypoints":
                recorder.full_track = result
            if name == "read_first_frame":
                recorder.first_frame = result
            if name in HASHED_RESULTS:
                entry["result"] = {
                    "$hash": fnv1a64_rows(np.asarray(result, np.uint8)),
                    "count": int(np.count_nonzero(result)),
                }
            else:
                entry["result"] = recorder.encode(result)
            for mutated in MUTATED.get(name, ()):
                entry.setdefault("after", {})[mutated] = recorder.encode(bound.arguments[mutated])
            recorder.calls.append(entry)
            return result

        return wrapper

    def _record_batch(self, fn, qualname, bound):
        """_nearest_contact_in_batch: record frame numbers, boxes and the runner masks the
        segmenter returned (the images themselves are not recorded)."""
        batch = bound.arguments["batch"]
        segmenter = _RecordingSegmenter(bound.arguments["segmenter"])
        bound.arguments["segmenter"] = segmenter
        entry = {
            "fn": qualname,
            "args": {
                "batch": [{"frame": int(f), "box": self.encode(np.asarray(box, float))} for f, _, box in batch],
                "sand_y": self.encode(bound.arguments["sand_y"]),
                "rule": self.encode(bound.arguments["rule"]),
                "board_on_right": bool(bound.arguments["board_on_right"]),
                "best": self.encode(bound.arguments["best"]),
            },
        }
        result = fn(*bound.args, **bound.kwargs)
        entry["masks"] = [None if m is None else self.encode(m) for m in segmenter.masks]
        entry["result"] = self.encode(result)
        self.calls.append(entry)
        return result


class _RecordingSegmenter:
    def __init__(self, inner) -> None:
        self.inner = inner
        self.masks: list = []

    def runner_masks(self, frames, boxes):
        masks = self.inner.runner_masks(frames, boxes)
        self.masks.extend(masks)
        return masks


def install(recorder_ref: list) -> None:
    """Replace every recorded function, in its module and in each core.longjump module that
    imported it, by a wrapper that records into recorder_ref[0]."""
    import importlib

    modules = {name: importlib.import_module(name) for name in RECORDED}
    for extra in ("core.longjump.step_events",):
        modules[extra] = importlib.import_module(extra)
    for module_name, names in RECORDED.items():
        for name in names:
            original = getattr(modules[module_name], name)
            qualname = f"{module_name}.{name}"

            def make(original=original, qualname=qualname):
                @functools.wraps(original)
                def dispatch(*args, **kwargs):
                    return recorder_ref[0].wrap(qualname, original)(*args, **kwargs)

                return dispatch

            wrapper = make()
            for module in list(sys.modules.values()):
                if getattr(module, "__name__", "").startswith("core.longjump") and getattr(
                    module, name, None
                ) is original:
                    setattr(module, name, wrapper)


# ------------------------------------------------------------------------------- cases


def gt_cases(gt_run: Path) -> list[dict]:
    cases = []
    for jump_dir in sorted(p for p in gt_run.iterdir() if p.is_dir()):
        keypoints = jump_dir / "pose" / "keypoints_2d.json"
        segment = GT_SEGMENTS / f"{jump_dir.name}.mp4"
        if not keypoints.exists() or not segment.exists():
            continue
        number = jump_dir.name.split("跳")[0].replace("第", "")
        cases.append(
            {
                "name": f"gt_{number}_{jump_dir.name.split('_')[-1]}",
                "kind": "gt",
                "source": str(jump_dir),
                "keypoints": keypoints,
                "video": segment,
                "pit": None,
            }
        )
    return cases


def session_cases(pipeline: Path) -> list[dict]:
    configs = CONFIG_WORK / "configs"
    missing = [p for p in BACKEND_SESSIONS if not (configs / f"{p}.json").exists()]
    if missing:
        subprocess.run(
            [sys.executable, "-m", "scripts.eval.rebuild_backend_configs", "--sessions", *missing,
             "--work", str(CONFIG_WORK)],
            cwd=pipeline,
            check=True,
        )
    from scripts.eval.regression_check import session_dir

    cases = []
    for prefix in BACKEND_SESSIONS:
        config = json.loads((configs / f"{prefix}.json").read_text())
        camera = config["cameras"][-1]
        folder = session_dir(prefix)
        cases.append(
            {
                "name": f"session_{prefix}",
                "kind": "session",
                "source": str(folder),
                "keypoints": folder / "pose" / "keypoints_2d.json",
                "video": Path(camera["video_path"]),
                "pit": camera,
            }
        )
    return cases


def track_signals(track) -> dict:
    return {
        "length": len(track.frames),
        "fps": track.fps,
        "bottom_y": track.bottom_y,
        "box_heights": track.box_heights,
        "hip_speed_toward_pit": track.hip_speed_toward_pit(),
        "slowest_foot_speed": track.slowest_foot_speed(),
        "toe_speed_left": track.toe_center_speed_2d_per_s("left"),
        "toe_speed_right": track.toe_center_speed_2d_per_s("right"),
    }


def run_case(case: dict, out_dir: Path, recorder_ref: list) -> dict:
    from core.longjump.analysis import analyse_long_jump
    from core.longjump.detection import load_pose_track_from_keypoints
    from core.longjump.pit_homography import PitCalibration

    case_dir = out_dir / case["name"]
    if case_dir.exists():
        shutil.rmtree(case_dir / "pose", ignore_errors=True)
        shutil.rmtree(case_dir / "longjump", ignore_errors=True)  # stale sand-mark cache
    (case_dir / "pose").mkdir(parents=True, exist_ok=True)
    keypoints = case_dir / "pose" / "keypoints_2d.json"
    shutil.copyfile(case["keypoints"], keypoints)

    document = json.loads(keypoints.read_text())
    cameras = {int(f.get("camera_index", 0)) for f in document["frames"] if f["valid"]}
    camera_index = max(cameras) if cameras else None
    pit = PitCalibration.from_camera(case["pit"]) if case["pit"] else None

    recorder = Recorder()
    recorder_ref[0] = recorder
    result = analyse_long_jump(keypoints, case["video"], pit, camera_index=camera_index)
    recorder_ref[0] = Recorder()  # nothing below is recorded
    failed = [w for w in result.get("warnings", []) if w.startswith("sand_mark_failed")]
    if failed:
        sys.exit(f"{case['name']}: {failed[0]} (the recorder or the segmentation environment broke)")

    full = load_pose_track_from_keypoints(keypoints, camera_index)
    trims = [c for c in recorder.calls if c["fn"].endswith(".find_trim_end")]
    signals = {"full": recorder.encode(track_signals(full))}
    if trims:
        signals["trimmed"] = recorder.encode(track_signals(full.until(trims[0]["result"]["end_index"])))

    first = None
    if recorder.first_frame is not None:
        frame = np.ascontiguousarray(recorder.first_frame)
        (case_dir / "first_frame.bgr").write_bytes(frame.tobytes())
        first = {
            "file": "first_frame.bgr",
            "width": int(frame.shape[1]),
            "height": int(frame.shape[0]),
            "channels": 3,
            "order": "BGR",
            "fnv1a64_rows": fnv1a64_rows(frame),
        }
    case_doc = {
        "name": case["name"],
        "kind": case["kind"],
        "source": case["source"],
        "video": str(case["video"]),
        "camera_index": camera_index,
        "pit": None
        if pit is None
        else {
            "image_points": pit.image_points.tolist(),
            "world_points": pit.world_points.tolist(),
            "board_offset_m": pit.board_offset_m,
        },
        "first_frame": first,
        "signals": signals,
    }
    (case_dir / "case.json").write_text(json.dumps(case_doc, indent=1, ensure_ascii=False))
    (case_dir / "calls.json").write_text(json.dumps({"calls": recorder.calls}, ensure_ascii=False))
    (case_dir / "result.json").write_text(
        json.dumps(recorder.encode(result), indent=1, ensure_ascii=False)
    )
    counts = {}
    for call in recorder.calls:
        short = call["fn"].rsplit(".", 1)[1]
        counts[short] = counts.get(short, 0) + 1
    print(
        f"[fixtures] {case['name']}: {result['status']} "
        f"{(result.get('distance') or {}).get('official_m')} m, {len(recorder.calls)} calls",
        flush=True,
    )
    return {
        "name": case["name"],
        "kind": case["kind"],
        "status": result["status"],
        "has_pit": pit is not None,
        "has_first_frame": first is not None,
        "calls": counts,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=OUT_DEFAULT)
    parser.add_argument("--gt-run", type=Path, default=GT_RUN_DEFAULT)
    parser.add_argument("--only", help="substring of the case names to (re)generate")
    args = parser.parse_args()

    pipeline = pipeline_root()
    sys.path.insert(0, str(pipeline))
    os.chdir(pipeline)
    recorder_ref = [Recorder()]
    install(recorder_ref)

    cases = gt_cases(args.gt_run) + session_cases(pipeline)
    if args.only:
        cases = [c for c in cases if args.only in c["name"]]
    if any(c["pit"] for c in cases):
        from scripts.eval.common import require_tensorrt

        require_tensorrt()
    args.out.mkdir(parents=True, exist_ok=True)
    index_path = args.out / "index.json"
    index = json.loads(index_path.read_text()) if index_path.exists() else {"cases": []}
    entries = {entry["name"]: entry for entry in index["cases"]}
    for case in cases:
        entries[case["name"]] = run_case(case, args.out, recorder_ref)
    commit = subprocess.run(
        ["git", "describe", "--always", "--dirty"], cwd=pipeline, capture_output=True, text=True
    ).stdout.strip()
    index = {
        "pipeline_commit": commit,
        "gt_run": str(args.gt_run),
        "cases": [entries[name] for name in sorted(entries)],
    }
    index_path.write_text(json.dumps(index, indent=1, ensure_ascii=False))
    print(f"[fixtures] {len(index['cases'])} cases -> {args.out}")


if __name__ == "__main__":
    main()
